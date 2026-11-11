import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:torrentia/bitfield.dart';
import 'package:torrentia/messages.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/piece_manager.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/storage.dart';
import 'package:torrentia/utils.dart';

/// Limits how many peers we upload to at once.
class UploadSlots {
  final int max;
  int _used = 0;
  UploadSlots(this.max);

  bool tryAcquire() {
    if (_used >= max) return false;
    _used++;
    return true;
  }

  void release() => _used = _used > 0 ? _used - 1 : 0;
}

/// One BitTorrent peer wire connection (BEP 3).
class PeerConnection implements BlockSource {
  final Peer peer;
  final TorrentContent torrent;
  final PieceManager manager;
  final Storage storage;
  final UploadSlots uploadSlots;
  final bool inbound;

  /// Our peer id.
  final Uint8List localPeerId;
  final void Function(PeerConnection conn, String reason) onClosed;

  Socket? _socket;
  late final Bitfield peerHas = Bitfield(torrent.info.pieceCount);
  bool _gotHandshake = false;
  bool _closed = false;
  Uint8List? remotePeerId;

  /// Peer is choking us.
  bool amChoked = true;
  bool amInterested = false;
  bool peerInterested = false;
  bool _peerUnchoked = false; // we're uploading to the peer

  final _outstanding = <int, BlockRequest>{};
  final _pendingUploads = <int>{};
  int maxPipeline = 16;
  int _snubs = 0;

  /// Strikes for sending data that failed hash checks; 3 gets the peer banned.
  int _hashStrikes = 0;
  static const banStrikes = 3;

  /// Set when the peer sent corrupt data; the session refuses its IP afterwards.
  bool banned = false;

  /// Max queued upload requests per peer (each is one 16 KiB block).
  static const maxPendingUploads = 32;

  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;

  DateTime _lastReceived = DateTime.now();
  DateTime _lastSent = DateTime.now();
  DateTime _lastPiece = DateTime.now();
  Timer? _timer;
  int _ticks = 0;

  int downloaded = 0;
  int uploaded = 0;
  int _downloadedAtLastTick = 0;
  double downloadRate = 0;

  PeerConnection({
    required this.peer,
    required this.torrent,
    required this.manager,
    required this.storage,
    required this.uploadSlots,
    required this.onClosed,
    required this.localPeerId,
    Socket? socket,
  })  : _socket = socket,
        inbound = socket != null;

  bool get isConnected => _gotHandshake && !_closed;
  int get pieceCount => torrent.info.pieceCount;

  static int _key(int piece, int begin) => piece * 65536 + (begin ~/ blockSize);

  /// Connects (if outbound) and starts the protocol.
  Future<void> start() async {
    try {
      _socket ??= await Socket.connect(peer.ip, peer.port, timeout: const Duration(seconds: 8));
    } catch (e) {
      _close('connect failed: $e');
      return;
    }
    if (_closed) {
      _socket?.destroy();
      return;
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _socket!.listen(
      _onData,
      onError: (Object e) => _close('socket error: $e'),
      onDone: () => _close('closed by peer'),
      cancelOnError: true,
    );
    if (!inbound) _send(Messages.buildHandShake(torrent.infoHash, localPeerId));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void close([String reason = 'closed locally']) => _close(reason);

  void _send(Uint8List data) {
    if (_closed) return;
    try {
      _socket?.add(data);
      _lastSent = DateTime.now();
    } catch (e) {
      _close('write failed: $e');
    }
  }

  // ------------------------------------------------------------------ framing

  void _onData(Uint8List data) {
    _lastReceived = DateTime.now();
    if (_len + data.length > _buf.length) {
      final grown = Uint8List(max(_buf.length * 2, _len + data.length));
      grown.setRange(0, _len, _buf);
      _buf = grown;
    }
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;

    var off = 0;
    final view = ByteData.sublistView(_buf);
    while (!_closed) {
      if (!_gotHandshake) {
        if (_len - off < handshakeLength) break;
        _onHandshake(Uint8List.sublistView(_buf, off, off + handshakeLength));
        off += handshakeLength;
        continue;
      }
      if (_len - off < 4) break;
      final msgLen = view.getUint32(off);
      if (msgLen > 4 * 1024 * 1024) {
        _close('message too large ($msgLen bytes)');
        return;
      }
      if (_len - off < 4 + msgLen) break;
      try {
        _onMessage(Messages.parseMessage(Uint8List.sublistView(_buf, off, off + 4 + msgLen)));
      } catch (e) {
        _close('bad message: $e');
        return;
      }
      off += 4 + msgLen;
    }
    if (off > 0 && !_closed) {
      _buf.setRange(0, _len - off, _buf, off);
      _len -= off;
    }
  }

  void _onHandshake(Uint8List data) {
    final hs = Handshake.parse(data);
    if (hs == null) return _close('invalid handshake');
    if (!_bytesEqual(hs.infoHash, torrent.infoHash)) return _close('wrong info hash');
    if (_bytesEqual(hs.peerId, localPeerId)) return _close('connected to self');
    _gotHandshake = true;
    remotePeerId = hs.peerId;
    if (inbound) _send(Messages.buildHandShake(torrent.infoHash, localPeerId));
    if (!manager.have.isEmpty) _send(Messages.buildBitField(manager.have.bytes));
    manager.register(this);
    Log.debug('Connected to $peer (${inbound ? 'inbound' : 'outbound'})');
  }

  // ----------------------------------------------------------------- messages

  void _onMessage(PeerMessage msg) {
    switch (msg.id) {
      case MessageId.keepAlive:
        break;
      case MessageId.choke:
        amChoked = true;
        _releaseAll();
      case MessageId.unchoke:
        amChoked = false;
        _fill();
      case MessageId.interested:
        peerInterested = true;
        if (!_peerUnchoked && uploadSlots.tryAcquire()) {
          _peerUnchoked = true;
          _send(Messages.buildUnchoke());
        }
      case MessageId.notInterested:
        peerInterested = false;
        _chokePeer();
      case MessageId.have:
        final i = msg.haveIndex;
        if (i >= pieceCount || peerHas[i]) break;
        peerHas.set(i);
        manager.incrementAvailability(i);
        if (!amInterested && manager.needs(i)) _setInterested(true);
        _fill();
      case MessageId.bitfield:
        manager.removeAvailability(peerHas);
        final bf = Bitfield.fromBytes(msg.payload, pieceCount);
        for (final i in bf.setIndexes) {
          peerHas.set(i);
        }
        manager.addAvailability(peerHas);
        _setInterested(manager.isInteresting(peerHas));
        _fill();
      case MessageId.request:
        _onRequest(msg.requestFields);
      case MessageId.piece:
        final (index, begin, block) = msg.pieceFields;
        if (_outstanding.remove(_key(index, begin)) != null) {
          _lastPiece = DateTime.now();
          _snubs = 0;
        }
        downloaded += block.length;
        manager.onBlock(this, index, begin, block);
        _fill();
      case MessageId.cancel:
        final (index, begin, _) = msg.requestFields;
        _pendingUploads.remove(_key(index, begin));
      default:
        break; // port, extension protocol: unsupported, ignore
    }
  }

  void _onRequest((int, int, int) fields) {
    final (index, begin, length) = fields;
    if (!_peerUnchoked || index >= pieceCount || !manager.have[index]) return;
    // Only standard 16 KiB blocks, and a small queue, so peers can't make us
    // buffer large amounts of data.
    if (length <= 0 || length > blockSize || begin + length > torrent.info.pieceSize(index)) return;
    if (_pendingUploads.length >= maxPendingUploads) return;
    final key = _key(index, begin);
    _pendingUploads.add(key);
    storage.read(index * torrent.info.pieceLength + begin, length).then((data) {
      if (_closed || !_pendingUploads.remove(key) || !_peerUnchoked) return;
      _send(Messages.buildPiece(index, begin, data));
      uploaded += length;
    }, onError: (Object e) {
      _pendingUploads.remove(key);
      Log.debug('Upload read failed: $e');
    });
  }

  void _chokePeer() {
    if (!_peerUnchoked) return;
    _peerUnchoked = false;
    uploadSlots.release();
    _pendingUploads.clear();
    _send(Messages.buildChoke());
  }

  /// Announces a newly verified piece to the peer.
  void sendHave(int piece) => _send(Messages.buildHave(piece));

  void _setInterested(bool value) {
    if (value == amInterested) return;
    amInterested = value;
    _send(value ? Messages.buildInterested() : Messages.buildNotInterested());
  }

  // ----------------------------------------------------------------- requests

  void _fill() {
    if (_closed || !_gotHandshake || amChoked || !amInterested) return;
    final deficit = maxPipeline - _outstanding.length;
    if (deficit <= 0) return;
    final reqs = manager.pickBlocks(this, peerHas, deficit);
    if (reqs.isEmpty) return;
    final out = BytesBuilder(copy: false);
    for (final r in reqs) {
      _outstanding[_key(r.piece, r.begin)] = r;
      out.add(Messages.buildRequest(r.piece, r.begin, r.length));
    }
    if (_outstanding.length == reqs.length) _lastPiece = DateTime.now();
    _send(out.takeBytes());
  }

  void _releaseAll() {
    _outstanding.clear();
    manager.releaseRequests(this);
  }

  @override
  void cancelBlock(BlockRequest r) {
    if (_outstanding.remove(_key(r.piece, r.begin)) != null) {
      _send(Messages.buildCancel(r.piece, r.begin, r.length));
    }
  }

  @override
  void onHashFailure(int piece, {required bool sole}) {
    _hashStrikes += sole ? banStrikes : 1;
    if (_hashStrikes >= banStrikes) {
      banned = true;
      Log.warn('Banning $peer: sent corrupt data (piece $piece)');
      _close('sent corrupt data');
    }
  }

  @override
  void onWorkAvailable() {
    if (!amInterested && _gotHandshake && !peerHas.isEmpty && manager.isInteresting(peerHas)) {
      _setInterested(true);
    }
    _fill();
  }

  // --------------------------------------------------------------- liveness

  void _tick() {
    if (_closed) return;
    final now = DateTime.now();
    _ticks++;

    // Download rate (smoothed) and pipeline depth ~2 s worth of data.
    final delta = downloaded - _downloadedAtLastTick;
    _downloadedAtLastTick = downloaded;
    downloadRate = downloadRate * 0.7 + delta * 0.3;
    maxPipeline = ((downloadRate * 2) / blockSize).ceil().clamp(8, 250);

    if (!_gotHandshake && now.difference(_lastReceived) > const Duration(seconds: 15)) {
      return _close('handshake timeout');
    }
    if (now.difference(_lastReceived) > const Duration(minutes: 3)) return _close('idle timeout');
    if (now.difference(_lastSent) > const Duration(seconds: 90)) _send(Messages.buildKeepAlive());

    // Snubbed: requests outstanding but nothing delivered for a while.
    if (_outstanding.isNotEmpty && now.difference(_lastPiece) > const Duration(seconds: 20)) {
      _snubs++;
      Log.debug('$peer snubbed us ($_snubs)');
      _releaseAll();
      _lastPiece = now;
      if (_snubs >= 3) return _close('snubbed');
    }

    if (_ticks % 10 == 0 && _gotHandshake) _setInterested(manager.isInteresting(peerHas));
    _fill();
  }

  void _close(String reason) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _socket?.destroy();
    if (_gotHandshake) {
      manager.unregister(this);
      manager.removeAvailability(peerHas);
    }
    _outstanding.clear();
    if (_peerUnchoked) uploadSlots.release();
    Log.debug('Disconnected from $peer: $reason');
    onClosed(this, reason);
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
