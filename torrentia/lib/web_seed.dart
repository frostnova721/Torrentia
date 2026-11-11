import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:torrentia/piece_manager.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/storage.dart';
import 'package:torrentia/utils.dart';

/// Downloads blocks from an HTTP mirror (BEP 19 "GetRight" style web seed).
class WebSeed implements BlockSource {
  final String url;
  final TorrentContent torrent;
  final PieceManager manager;
  final Storage storage;
  final int workers;

  /// Blocks fetched per HTTP request (64 × 16 KiB = 1 MiB).
  final int blocksPerRequest;

  final _client = http.Client();

  /// Files up to this size may be served whole by servers that ignore Range.
  static const smallFileLimit = 4 * 1024 * 1024;
  bool _running = false;
  int _failures = 0;
  Completer<void> _wake = Completer();
  int downloaded = 0;

  WebSeed(this.url, this.torrent, this.manager, this.storage, {this.workers = 3, this.blocksPerRequest = 64});

  bool get isActive => _running;

  /// Starts downloading. Refuses non-HTTP URLs and hosts on private networks
  /// (a malicious torrent could otherwise make us send requests into the LAN).
  Future<bool> start() async {
    if (_running) return true;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      Log.warn('Ignoring web seed with unsupported URL: $url');
      return false;
    }
    try {
      await NetworkPolicy.checkHost(uri.host);
    } catch (e) {
      Log.warn('Ignoring web seed $url: $e');
      return false;
    }
    _running = true;
    manager.register(this);
    for (var i = 0; i < workers; i++) {
      unawaited(_worker());
    }
    return true;
  }

  int _hashStrikes = 0;

  @override
  void onHashFailure(int piece, {required bool sole}) {
    _hashStrikes += sole ? 1 : 0;
    // A mirror that serves wrong data (e.g. a different file version) is useless.
    if (_hashStrikes >= 3 && _running) {
      Log.warn('Disabling web seed $url: it serves data that fails hash checks');
      stop();
    }
  }

  void stop() {
    if (!_running) return;
    _running = false;
    manager.unregister(this);
    _client.close();
    onWorkAvailable();
  }

  /// URL of a file on this mirror.
  Uri fileUri(TorrentInfoFile file) {
    final base = url.endsWith('/') ? url : '$url/';
    if (!torrent.info.isMultiFile) {
      return Uri.parse(url.endsWith('/') ? '$base${Uri.encodeComponent(file.name)}' : url);
    }
    return Uri.parse(base + file.pathSegments.map(Uri.encodeComponent).join('/'));
  }

  Future<void> _worker() async {
    while (_running) {
      final reqs = manager.pickBlocks(this, null, blocksPerRequest);
      if (reqs.isEmpty) {
        await Future.any([_wake.future, Future.delayed(const Duration(seconds: 5))]);
        if (_wake.isCompleted) _wake = Completer();
        continue;
      }

      // Group into contiguous byte ranges so each becomes one HTTP request.
      final pieceLength = torrent.info.pieceLength;
      reqs.sort((a, b) => (a.piece * pieceLength + a.begin).compareTo(b.piece * pieceLength + b.begin));
      final groups = <List<BlockRequest>>[];
      for (final r in reqs) {
        final last = groups.isEmpty ? null : groups.last.last;
        if (last != null &&
            last.piece * pieceLength + last.begin + last.length == r.piece * pieceLength + r.begin) {
          groups.last.add(r);
        } else {
          groups.add([r]);
        }
      }

      final pending = reqs.toSet();
      try {
        for (final g in groups) {
          if (!_running) break;
          final start = g.first.piece * pieceLength + g.first.begin;
          final length = g.fold<int>(0, (sum, r) => sum + r.length);
          final data = await _fetch(start, length);
          var off = 0;
          for (final r in g) {
            manager.onBlock(this, r.piece, r.begin, Uint8List.sublistView(data, off, off + r.length));
            pending.remove(r);
            off += r.length;
          }
          downloaded += length;
        }
        _failures = 0;
      } catch (e) {
        _failures++;
        Log.debug('Web seed $url failed ($_failures): $e');
        for (final r in pending) {
          manager.releaseRequest(this, r);
        }
        if (_failures >= 10) {
          Log.warn('Disabling web seed $url after repeated failures');
          stop();
          return;
        }
        await Future.delayed(Duration(seconds: min(2 << _failures, 60)));
      }
    }
  }

  Future<Uint8List> _fetch(int offset, int length) async {
    final out = Uint8List(length);
    for (final s in storage.slices(offset, length)) {
      final file = torrent.info.files[s.fileIndex];
      final req = http.Request('GET', fileUri(file))
        ..maxRedirects = 3
        ..headers['Range'] = 'bytes=${s.fileOffset}-${s.fileOffset + s.length - 1}';
      final res = await _client.send(req).timeout(const Duration(seconds: 20));
      // Never read more than we asked for: a server that ignores Range could
      // otherwise make us buffer a multi-gigabyte file in memory.
      if (res.statusCode == 206) {
        final body = await readLimited(res.stream, s.length).timeout(const Duration(seconds: 60));
        if (body.length != s.length) throw Exception('Short response: ${body.length}/${s.length} bytes');
        out.setRange(s.rangeOffset, s.rangeOffset + s.length, body);
      } else if (res.statusCode == 200 && file.size <= smallFileLimit && res.contentLength == file.size) {
        // Server ignored Range; acceptable only for small files.
        final body = await readLimited(res.stream, file.size).timeout(const Duration(seconds: 60));
        if (body.length != file.size) throw Exception('Short response');
        out.setRange(s.rangeOffset, s.rangeOffset + s.length, body, s.fileOffset);
      } else {
        unawaited(res.stream.listen(null).cancel()); // discard without reading
        throw Exception('HTTP ${res.statusCode} for a ${s.length}-byte range');
      }
    }
    return out;
  }

  @override
  void cancelBlock(BlockRequest request) {}

  @override
  void onWorkAvailable() {
    if (!_wake.isCompleted) _wake.complete();
  }
}
