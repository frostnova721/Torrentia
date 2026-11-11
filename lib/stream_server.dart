import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:torrentia/reader.dart';
import 'package:torrentia/session.dart';
import 'package:torrentia/utils.dart';

const _mimeTypes = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mov': 'video/quicktime',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  'mpg': 'video/mpeg',
  'mpeg': 'video/mpeg',
  'wmv': 'video/x-ms-wmv',
  'flv': 'video/x-flv',
  'ogv': 'video/ogg',
  'm3u8': 'application/vnd.apple.mpegurl',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'srt': 'text/plain; charset=utf-8',
  'vtt': 'text/vtt; charset=utf-8',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'txt': 'text/plain; charset=utf-8',
};

/// Content type for a file name. Anything unknown (including .html/.svg from a
/// torrent) is served as an opaque download, never as something a browser runs.
String mimeTypeFor(String name) =>
    _mimeTypes[name.split('.').last.toLowerCase()] ?? 'application/octet-stream';

/// Serves torrent files over HTTP while they download. Range requests set
/// the download priority, so seeking in a player jumps the download there.
///
/// Every URL starts with a random secret [token], so other apps on the device
/// and web pages open in a browser can't read what's being served:
/// - `/<token>/`                      : index page with a player and file list
/// - `/<token>/status`                : JSON progress
/// - `/<token>/stream/<index>/<name>` : file by index
/// - `/<token>/files/<path>`          : file by path (relative URLs in HLS playlists work)
class StreamServer {
  final TorrentSession session;
  final int port;
  final InternetAddress address;

  /// Secret path prefix. Random by default.
  final String token;

  /// Concurrent file responses allowed (players open a few; more is abuse).
  final int maxStreams;

  /// Give up on a response if the next piece doesn't arrive within this time.
  final Duration stallTimeout;

  HttpServer? _server;
  int _activeStreams = 0;

  StreamServer(
    this.session, {
    this.port = 8888,
    InternetAddress? address,
    String? token,
    this.maxStreams = 16,
    this.stallTimeout = const Duration(seconds: 90),
  })  : address = address ?? InternetAddress.loopbackIPv4,
        token = token ?? _randomToken();

  static String _randomToken() {
    final r = Random.secure();
    return TorrentiaUtils.toHex(List.generate(16, (_) => r.nextInt(256)));
  }

  int get boundPort => _server?.port ?? port;
  String get _host => address.address == '0.0.0.0' ? 'localhost' : address.address;

  /// Base URL including the token, e.g. `http://127.0.0.1:8888/3f9a...`.
  String get baseUrl => 'http://$_host:$boundPort/$token';

  String streamUrl(int fileIndex) =>
      '$baseUrl/stream/$fileIndex/${Uri.encodeComponent(session.torrent.info.files[fileIndex].name)}';

  Future<void> start() async {
    _server = await HttpServer.bind(address, port);
    _server!.listen((req) => unawaited(_handle(req)));
  }

  Future<void> close() async => _server?.close(force: true);

  /// Blocks DNS rebinding: when bound to loopback, only accept requests
  /// addressed to a loopback host name.
  bool _hostAllowed(HttpRequest req) {
    if (!address.isLoopback) return true;
    final host = req.headers.host?.toLowerCase();
    return host == null || host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';
  }

  Future<void> _plain(HttpResponse res, int status, [String body = '']) {
    res.statusCode = status;
    if (body.isNotEmpty) res.write(body);
    return res.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // Deliberately no CORS headers: web pages must not read these responses.
    res.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer') // don't leak the token to other sites
      ..set('Cross-Origin-Resource-Policy', 'same-origin');
    try {
      if (!_hostAllowed(req)) return await _plain(res, HttpStatus.forbidden);
      if (req.method != 'GET' && req.method != 'HEAD') return await _plain(res, HttpStatus.methodNotAllowed);

      final all = req.uri.pathSegments;
      if (all.isEmpty || !_constantTimeEquals(all.first, token)) {
        return await _plain(res, HttpStatus.notFound, 'Not found');
      }
      if (req.uri.path == '/$token') {
        // So relative URLs on the index page resolve under the token.
        return await res.redirect(Uri(path: '/$token/'), status: HttpStatus.movedPermanently);
      }
      final segments = all.skip(1).where((s) => s.isNotEmpty).toList();

      if (segments.isEmpty) return await _index(res);
      if (segments.first == 'status') return await _status(res);

      final fileIndex = switch (segments.first) {
        'stream' when segments.length >= 2 => int.tryParse(segments[1]),
        'files' => _fileByPath(segments.skip(1).join('/')),
        _ => null,
      };
      final files = session.torrent.info.files;
      if (fileIndex == null || fileIndex < 0 || fileIndex >= files.length) {
        return await _plain(res, HttpStatus.notFound, 'Not found');
      }

      if (_activeStreams >= maxStreams) {
        res.headers.set(HttpHeaders.retryAfterHeader, '2');
        return await _plain(res, HttpStatus.serviceUnavailable);
      }
      _activeStreams++;
      try {
        await _serveFile(req, files[fileIndex]);
      } finally {
        _activeStreams--;
      }
    } catch (e) {
      Log.debug('HTTP ${req.uri.path.replaceFirst(token, '<token>')}: $e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  int? _fileByPath(String path) {
    final files = session.torrent.info.files;
    for (var i = 0; i < files.length; i++) {
      // Multi-file paths start with the torrent name; accept with or without it.
      if (files[i].path == path || files[i].pathSegments.skip(1).join('/') == path) return i;
    }
    return null;
  }

  Future<void> _serveFile(HttpRequest req, TorrentInfoFile file) async {
    final res = req.response;
    final size = file.size;
    res.headers
      ..contentType = ContentType.parse(mimeTypeFor(file.name))
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');

    var start = 0;
    var end = size - 1;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final parsed = parseRange(range, size);
      if (parsed == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        return res.close();
      }
      (start, end) = parsed;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
    }
    res.contentLength = size == 0 ? 0 : end - start + 1;
    if (req.method == 'HEAD' || size == 0) return res.close();

    final manager = session.manager;
    final info = session.torrent.info;
    final (firstPiece, lastPiece) = info.piecesForFile(file);
    manager.wantRange(firstPiece, lastPiece);

    Log.debug('Streaming ${file.name} bytes $start-$end');
    final cursor = manager.openCursor(file.offset + start);
    var clientGone = false;
    final done = res.done.then((_) {}, onError: (_) {});
    unawaited(done.whenComplete(() => clientGone = true));
    try {
      var pos = file.offset + start;
      final stop = file.offset + end + 1;
      while (pos < stop && !clientGone) {
        cursor.seek(pos);
        final piece = pos ~/ info.pieceLength;
        // Wait for the piece, the client leaving, or a stall; never forever.
        await Future.any([manager.waitForPiece(piece), done, Future<void>.delayed(stallTimeout)]);
        if (clientGone) break;
        if (!manager.have[piece]) {
          Log.debug('Stream stalled waiting for piece $piece; closing response');
          break;
        }
        final chunkEnd = min(stop, (piece + 1) * info.pieceLength);
        final data = await session.storage.read(pos, chunkEnd - pos);
        res.add(data);
        await res.flush();
        pos = chunkEnd;
      }
    } finally {
      cursor.close();
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _status(HttpResponse res) {
    final m = session.manager;
    res.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    res.write(jsonEncode({
      'name': session.torrent.info.name,
      'infoHash': session.torrent.infoHashHex,
      'piecesHave': m.have.count,
      'pieces': session.torrent.info.pieceCount,
      'wantedHave': m.wantedHaveCount,
      'wanted': m.wantedCount,
      'downloadRate': session.downloadRate.round(),
      'peers': session.connectedPeers,
      'status': session.statusLine(),
    }));
    return res.close();
  }

  Future<void> _index(HttpResponse res) {
    final files = session.torrent.info.files;
    final main = session.defaultFileIndex;
    // File names come from the torrent and are attacker-controlled: escape
    // everything, and keep URLs out of JavaScript (data attributes only).
    const text = HtmlEscape(HtmlEscapeMode.element);
    const attr = HtmlEscape(HtmlEscapeMode.attribute);
    final rows = [
      for (var i = 0; i < files.length; i++)
        '<li><a href="${attr.convert(streamUrl(i))}">${text.convert(files[i].path)}</a> '
            '<span>${TorrentiaUtils.formatBytes(files[i].size)}</span> '
            '<button data-src="${attr.convert(streamUrl(i))}">play</button></li>'
    ].join('\n');
    final nonce = _randomToken();
    res.headers
      ..contentType = ContentType.html
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Frame-Options', 'DENY')
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; "
            "media-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
      );
    res.write('''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Torrentia</title>
<style>
body{font-family:system-ui,sans-serif;margin:0 auto;max-width:960px;padding:16px;background:#111;color:#eee}
video{width:100%;background:#000;border-radius:6px}
a{color:#7ab7ff}li{margin:6px 0}span{color:#999;margin:0 8px}
#status{font-family:monospace;color:#9c9;margin:8px 0}
button{background:#333;color:#eee;border:1px solid #555;border-radius:4px;cursor:pointer}
</style></head><body>
<h2>${text.convert(session.torrent.info.name)}</h2>
<video id="v" controls autoplay src="${attr.convert(streamUrl(main))}"></video>
<div id="status"></div>
<p>Browsers can't play every container (e.g. most MKV). Open a file link in VLC or mpv instead.</p>
<ul>$rows</ul>
<script nonce="$nonce">
const v = document.getElementById('v');
document.querySelectorAll('button[data-src]').forEach((b) =>
  b.addEventListener('click', () => { v.src = b.dataset.src; v.play(); }));
async function poll() {
  try {
    const s = await (await fetch('status')).json();
    document.getElementById('status').textContent = s.status;
  } catch (e) {}
}
setInterval(poll, 1000);
poll();
</script></body></html>''');
    return res.close();
  }
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Parses a single `bytes=` range. Returns inclusive (start, end) or null if unsatisfiable.
(int, int)? parseRange(String header, int size) {
  final m = RegExp(r'^\s*bytes\s*=\s*(\d{0,18})\s*-\s*(\d{0,18})\s*(?:,.*)?$').firstMatch(header);
  if (m == null || size == 0) return null;
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  if (a.isEmpty) {
    final suffix = int.parse(b);
    if (suffix == 0) return null;
    return (max(0, size - suffix), size - 1);
  }
  final start = int.parse(a);
  final end = b.isEmpty ? size - 1 : min(int.parse(b), size - 1);
  if (start >= size || end < start) return null;
  return (start, end);
}
