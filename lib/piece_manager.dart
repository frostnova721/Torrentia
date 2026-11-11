import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:torrentia/bitfield.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/storage.dart';
import 'package:torrentia/utils.dart';

/// Standard request size. Peers drop connections that ask for more than 16 KiB.
const int blockSize = 16 * 1024;

/// Anything that downloads blocks: peer connections and web seeds.
abstract class BlockSource {
  /// A block this source requested was received from someone else.
  void cancelBlock(BlockRequest request);

  /// New work may be available (a stream position moved, a piece failed, ...).
  void onWorkAvailable();

  /// A piece this source contributed to failed its hash check.
  /// [sole] is true if this source sent every block of it.
  void onHashFailure(int piece, {required bool sole});
}

class BlockRequest {
  final int piece;
  final int begin;
  final int length;

  const BlockRequest(this.piece, this.begin, this.length);

  @override
  bool operator ==(Object other) =>
      other is BlockRequest && other.piece == piece && other.begin == begin && other.length == length;

  @override
  int get hashCode => Object.hash(piece, begin, length);

  @override
  String toString() => 'BlockRequest($piece, $begin, $length)';
}

class _Req {
  final BlockSource source;
  final DateTime at;
  _Req(this.source, this.at);
}

class _ActivePiece {
  final int index;
  final int length;
  final Uint8List data;
  final Uint8List received;
  final List<List<_Req>> requests;

  /// Who delivered each block, to blame them if the piece fails its hash.
  final List<BlockSource?> deliveredBy;
  int receivedCount = 0;
  bool verifying = false;

  _ActivePiece(this.index, this.length)
      : data = Uint8List(length),
        received = Uint8List((length + blockSize - 1) ~/ blockSize),
        requests = List.generate((length + blockSize - 1) ~/ blockSize, (_) => <_Req>[]),
        deliveredBy = List.filled((length + blockSize - 1) ~/ blockSize, null);

  int get blocks => received.length;
  int blockLength(int b) => min(blockSize, length - b * blockSize);

  void reset() {
    received.fillRange(0, received.length, 0);
    receivedCount = 0;
    verifying = false;
    for (final r in requests) {
      r.clear();
    }
    deliveredBy.fillRange(0, deliveredBy.length, null);
  }
}

/// How pieces outside stream readahead windows are chosen.
enum PieceStrategy {
  /// Sequential from the playback position, file head/tail early. Best for watching.
  streaming,

  /// Rarest pieces first (random order for the first few pieces). Best total
  /// throughput: rare pieces are fetched while their owners are around, load is
  /// spread over more peers, and we quickly hold pieces others want to trade for.
  rarestFirst,
}

/// A playback position. Pieces just ahead of it are downloaded first.
class StreamCursor {
  final PieceManager _manager;
  int _piece;
  bool _closed = false;

  StreamCursor._(this._manager, this._piece);

  int get piece => _piece;
  bool get isClosed => _closed;

  /// Moves the cursor to a torrent byte offset.
  void seek(int byteOffset) {
    final p = min(byteOffset ~/ _manager.info.pieceLength, _manager.info.pieceCount - 1);
    if (p == _piece) return;
    _piece = p;
    _manager._lastStreamPiece = p;
    _manager._notifySources();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _manager._cursors.remove(this);
  }
}

/// Tracks which pieces we have, decides what to request next, assembles
/// and verifies pieces, and hands verified data to [Storage].
class PieceManager {
  final TorrentContent torrent;
  final Storage storage;

  /// How far ahead of each stream cursor to prioritise.
  final int readaheadBytes;

  /// The part of the readahead treated as urgent (requested from several
  /// sources at once if slow).
  final int urgentBytes;

  /// Memory limit for partially downloaded pieces (urgent pieces may exceed it).
  final int maxActiveBytes;

  final Duration requestTimeout;
  final Duration urgentTimeout;

  late final Bitfield have = Bitfield(info.pieceCount);
  late final Bitfield wanted = Bitfield.full(info.pieceCount);
  late final List<int> availability = List.filled(info.pieceCount, 0);

  final _active = <int, _ActivePiece>{};
  int _activeBytes = 0;
  final _waiters = <int, Completer<void>>{};
  final _cursors = <StreamCursor>[];
  final _highPriority = <int>{};
  final _sources = <BlockSource>{};
  final _verified = StreamController<int>.broadcast(sync: true);
  bool _notifyScheduled = false;
  int _lastStreamPiece = 0;
  int _wantedMissing = 0;

  final PieceStrategy strategy;

  /// Pieces this many or fewer completed use random order instead of rarest:
  /// a complete piece quickly gives us something to trade.
  static const randomFirstPieces = 4;

  /// Cached rarest-first order; rebuilt at most once a second when availability changes.
  List<int>? _rarest;
  bool _rarestDirty = true;
  DateTime _rarestBuiltAt = DateTime.fromMillisecondsSinceEpoch(0);
  late final List<int> _tiebreak = () {
    final r = Random();
    return List.generate(info.pieceCount, (_) => r.nextInt(1 << 30));
  }();

  /// Payload bytes received from all sources (including waste).
  int receivedBytes = 0;

  /// Bytes in pieces that passed the hash check.
  int verifiedBytes = 0;

  /// Bytes thrown away (duplicates, failed hashes).
  int wastedBytes = 0;
  int hashFailures = 0;

  PieceManager(
    this.torrent,
    this.storage, {
    this.readaheadBytes = 24 * 1024 * 1024,
    this.urgentBytes = 3 * 1024 * 1024,
    this.maxActiveBytes = 192 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 30),
    this.urgentTimeout = const Duration(seconds: 3),
    this.strategy = PieceStrategy.streaming,
  }) {
    _wantedMissing = info.pieceCount;
  }

  TorrentInfo get info => torrent.info;

  /// Emits each piece index once it's verified and written.
  Stream<int> get onPieceVerified => _verified.stream;

  int get _windowPieces => max(3, (readaheadBytes / info.pieceLength).ceil());
  int get _urgentPieces => max(1, (urgentBytes / info.pieceLength).ceil());

  /// True when every wanted piece is downloaded.
  bool get isComplete => _wantedMissing == 0;

  int get wantedCount => wanted.count;
  int get wantedHaveCount => wanted.count - _wantedMissing;

  // ---------------------------------------------------------------- selection

  /// Restricts background downloading to [pieces]. Streamed ranges are
  /// always downloaded regardless.
  void setWanted(Iterable<int> pieces) {
    final set = pieces.toSet();
    for (var i = 0; i < info.pieceCount; i++) {
      wanted.set(i, set.contains(i));
    }
    _recountWanted();
  }

  void wantRange(int first, int last) {
    for (var i = first; i <= last; i++) {
      wanted.set(i);
    }
    _recountWanted();
  }

  void _recountWanted() {
    var missing = 0;
    for (var i = 0; i < info.pieceCount; i++) {
      if (wanted[i] && !have[i]) missing++;
    }
    _wantedMissing = missing;
    _rarest = null;
    _notifySources();
  }

  /// Pieces fetched before the general sequential order, e.g. the start and
  /// end of a video file, where containers keep their index.
  void setHighPriority(Iterable<int> pieces) {
    _highPriority
      ..clear()
      ..addAll(pieces);
    _notifySources();
  }

  /// Marks pieces found on disk at startup.
  void markHave(Iterable<int> pieces) {
    for (final p in pieces) {
      if (have[p]) continue;
      have.set(p);
      verifiedBytes += info.pieceSize(p);
    }
    _recountWanted();
  }

  StreamCursor openCursor(int byteOffset) {
    final c = StreamCursor._(this, min(byteOffset ~/ info.pieceLength, info.pieceCount - 1));
    _cursors.add(c);
    _lastStreamPiece = c.piece;
    _notifySources();
    return c;
  }

  /// Completes once [piece] is verified and on disk.
  Future<void> waitForPiece(int piece) {
    if (have[piece]) return Future.value();
    return (_waiters[piece] ??= Completer<void>()).future;
  }

  // ------------------------------------------------------------- availability

  void register(BlockSource s) => _sources.add(s);
  void unregister(BlockSource s) {
    _sources.remove(s);
    releaseRequests(s);
  }

  void addAvailability(Bitfield peerHas) {
    for (final i in peerHas.setIndexes) {
      availability[i]++;
    }
    _rarestDirty = true;
  }

  void removeAvailability(Bitfield peerHas) {
    for (final i in peerHas.setIndexes) {
      if (availability[i] > 0) availability[i]--;
    }
    _rarestDirty = true;
  }

  void incrementAvailability(int piece) {
    availability[piece]++;
    _rarestDirty = true;
  }

  /// Missing wanted pieces, rarest first (ties in a fixed random order).
  List<int> _rarestOrder() {
    final now = DateTime.now();
    final cached = _rarest;
    if (cached != null && (!_rarestDirty || now.difference(_rarestBuiltAt) < const Duration(seconds: 1))) {
      return cached;
    }
    final randomOnly = have.count < randomFirstPieces;
    final order = [
      for (var i = 0; i < info.pieceCount; i++)
        if (wanted[i] && !have[i]) i
    ];
    order.sort((a, b) {
      if (!randomOnly) {
        final c = availability[a].compareTo(availability[b]);
        if (c != 0) return c;
      }
      return _tiebreak[a].compareTo(_tiebreak[b]);
    });
    _rarestDirty = false;
    _rarestBuiltAt = now;
    return _rarest = order;
  }

  /// Whether we'd download [piece] (wanted or being streamed, and missing).
  bool needs(int piece) => !have[piece] && (wanted[piece] || _inAnyWindow(piece));

  /// Whether a peer with [peerHas] has anything we need.
  bool isInteresting(Bitfield peerHas) {
    for (var i = 0; i < info.pieceCount; i++) {
      if (peerHas[i] && needs(i)) return true;
    }
    return false;
  }

  bool _inAnyWindow(int piece) {
    for (final c in _cursors) {
      if (piece >= c.piece && piece < c.piece + _windowPieces) return true;
    }
    return false;
  }

  // ------------------------------------------------------------------ picking

  /// Piece candidates in priority order: (piece, urgent). [sequential] forces
  /// in-order background picking (web seeds want contiguous HTTP ranges).
  Iterable<(int, bool)> _candidates({bool sequential = false}) sync* {
    final seen = <int>{};
    final window = _windowPieces;
    final urgent = _urgentPieces;
    final cursors = List.of(_cursors);

    // 1. Readahead windows of all stream cursors, nearest first.
    for (var d = 0; d < window; d++) {
      for (final c in cursors) {
        final p = c.piece + d;
        if (p < info.pieceCount && !have[p] && seen.add(p)) yield (p, d < urgent);
      }
    }
    // 2. High-priority pieces (file head/tail).
    for (final p in List.of(_highPriority)) {
      if (!have[p] && seen.add(p)) yield (p, false);
    }
    // 3. Finish pieces already in progress.
    for (final p in List.of(_active.keys)) {
      if (!have[p] && seen.add(p)) yield (p, false);
    }
    // 4. Everything else wanted: rarest first, or sequentially from the last
    //    stream position.
    if (strategy == PieceStrategy.rarestFirst && !sequential) {
      for (final p in _rarestOrder()) {
        if (!have[p] && wanted[p] && !seen.contains(p)) yield (p, false);
      }
      return;
    }
    final start = cursors.isEmpty ? _lastStreamPiece : cursors.map((c) => c.piece).reduce(min);
    for (var i = 0; i < info.pieceCount; i++) {
      final p = (start + i) % info.pieceCount;
      if (wanted[p] && !have[p] && !seen.contains(p)) yield (p, false);
    }
  }

  /// Chooses up to [max] blocks for [source] to request. [peerHas] is null
  /// for sources that have everything (web seeds).
  List<BlockRequest> pickBlocks(BlockSource source, Bitfield? peerHas, int max) {
    final out = <BlockRequest>[];
    if (max <= 0) return out;
    final now = DateTime.now();

    void take(_ActivePiece pc, int b) {
      pc.requests[b].add(_Req(source, now));
      out.add(BlockRequest(pc.index, b * blockSize, pc.blockLength(b)));
    }

    // Rarity only matters among peers; an HTTP mirror has everything, so it
    // fetches in order to get long contiguous ranges.
    for (final (p, urgent) in _candidates(sequential: peerHas == null)) {
      if (out.length >= max) break;
      if (peerHas != null && !peerHas[p]) continue;

      var pc = _active[p];
      if (pc == null) {
        final size = info.pieceSize(p);
        if (!urgent && _activeBytes + size > maxActiveBytes) continue;
        pc = _active[p] = _ActivePiece(p, size);
        _activeBytes += size;
      }
      if (pc.verifying) continue;

      for (var b = 0; b < pc.blocks && out.length < max; b++) {
        if (pc.received[b] == 1) continue;
        final reqs = pc.requests[b];
        if (reqs.any((r) => identical(r.source, source))) continue;
        if (reqs.isEmpty) {
          take(pc, b);
        } else if (urgent && reqs.length < 3 && now.difference(reqs.last.at) > urgentTimeout) {
          take(pc, b); // slow block near the playhead: ask someone else as well
        } else if (now.difference(reqs.first.at) > requestTimeout) {
          take(pc, b); // stale request
        }
      }
    }

    // Endgame: every missing piece is in flight, so duplicate outstanding
    // blocks rather than leaving this source idle.
    if (out.length < max && _wantedMissing > 0 && _wantedMissing <= _active.length) {
      for (final pc in List.of(_active.values)) {
        if (out.length >= max) break;
        if (pc.verifying || (peerHas != null && !peerHas[pc.index])) continue;
        for (var b = 0; b < pc.blocks && out.length < max; b++) {
          final reqs = pc.requests[b];
          if (pc.received[b] == 1 || reqs.length >= 2) continue;
          if (reqs.any((r) => identical(r.source, source))) continue;
          take(pc, b);
        }
      }
    }
    return out;
  }

  /// Forgets all outstanding requests made by [source] (choked/disconnected).
  void releaseRequests(BlockSource source) {
    for (final pc in List.of(_active.values)) {
      for (final reqs in pc.requests) {
        reqs.removeWhere((r) => identical(r.source, source));
      }
      _maybeDrop(pc);
    }
    _notifySources();
  }

  void releaseRequest(BlockSource source, BlockRequest r) {
    final pc = _active[r.piece];
    if (pc == null) return;
    final b = r.begin ~/ blockSize;
    if (b < pc.blocks) pc.requests[b].removeWhere((x) => identical(x.source, source));
    _maybeDrop(pc);
  }

  /// Frees an untouched piece buffer.
  void _maybeDrop(_ActivePiece pc) {
    if (pc.receivedCount == 0 && !pc.verifying && pc.requests.every((r) => r.isEmpty)) {
      _active.remove(pc.index);
      _activeBytes -= pc.length;
    }
  }

  // ---------------------------------------------------------------- receiving

  /// Stores a received block. Returns false if it was unexpected or a duplicate.
  bool onBlock(BlockSource source, int piece, int begin, Uint8List data) {
    receivedBytes += data.length;
    final pc = _active[piece];
    final b = begin ~/ blockSize;
    if (pc == null || pc.verifying || begin % blockSize != 0 || b >= pc.blocks || data.length != pc.blockLength(b)) {
      wastedBytes += data.length;
      return false;
    }
    final reqs = pc.requests[b];
    if (pc.received[b] == 1) {
      wastedBytes += data.length;
      reqs.removeWhere((r) => identical(r.source, source));
      return false;
    }

    pc.data.setRange(begin, begin + data.length, data);
    pc.received[b] = 1;
    pc.deliveredBy[b] = source;
    pc.receivedCount++;

    final others = reqs.where((r) => !identical(r.source, source)).map((r) => r.source).toList();
    reqs.clear();
    final cancel = BlockRequest(piece, begin, data.length);
    for (final o in others) {
      o.cancelBlock(cancel);
    }

    if (pc.receivedCount == pc.blocks) unawaited(_finish(pc));
    return true;
  }

  Future<void> _finish(_ActivePiece pc) async {
    pc.verifying = true;
    if (!hashMatches(pc.data, info.pieceHashes[pc.index])) {
      hashFailures++;
      wastedBytes += pc.length;
      Log.warn('Piece ${pc.index} failed hash check, retrying');
      final contributors = pc.deliveredBy.whereType<BlockSource>().toSet();
      pc.reset();
      for (final c in contributors) {
        c.onHashFailure(pc.index, sole: contributors.length == 1);
      }
      _notifySources();
      return;
    }
    try {
      await storage.writePiece(pc.index, pc.data);
    } catch (e) {
      Log.error('Failed to write piece ${pc.index}: $e');
      pc.reset();
      _notifySources();
      return;
    }

    _active.remove(pc.index);
    _activeBytes -= pc.length;
    have.set(pc.index);
    verifiedBytes += pc.length;
    if (wanted[pc.index]) _wantedMissing--;
    if (have.count == randomFirstPieces) _rarest = null; // switch from random to rarest
    _waiters.remove(pc.index)?.complete();
    _verified.add(pc.index);
  }

  void _notifySources() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      for (final s in List.of(_sources)) {
        s.onWorkAvailable();
      }
    });
  }

  Future<void> close() async {
    await _verified.close();
  }
}
