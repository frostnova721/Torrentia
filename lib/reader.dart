import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:torrentia/bencode.dart';
import 'package:torrentia/utils.dart';

/// Limits that keep a malicious torrent from exhausting memory.
const maxTorrentFileBytes = 32 * 1024 * 1024;
const maxPieceLength = 64 * 1024 * 1024;
const maxFiles = 100000;

/// Parses `.torrent` (metainfo) files. Any malformed input raises a
/// [FormatException], never another error type.
class Reader {
  Future<TorrentContent> readFromFile(String path) async {
    final file = File(path);
    if (await file.length() > maxTorrentFileBytes) throw const FormatException('Torrent file too large');
    return parse(await file.readAsBytes());
  }

  TorrentContent parse(Uint8List bytes) {
    try {
      return _parse(bytes);
    } on FormatException {
      rethrow;
    } on BencodeException catch (e) {
      throw FormatException('Invalid torrent: ${e.message}');
    } catch (e) {
      throw FormatException('Invalid torrent: $e');
    }
  }

  TorrentContent _parse(Uint8List bytes) {
    final decoded = bdecode(bytes);
    final root = decoded.value;
    if (root is! Map<String, dynamic>) throw const FormatException('Torrent root is not a dictionary');

    final info = root['info'];
    final infoSpan = decoded.topLevelSpans['info'];
    if (info is! Map<String, dynamic> || infoSpan == null) {
      throw const FormatException('Torrent has no info dictionary');
    }

    // The info hash must be computed over the exact bytes in the file.
    // Re-encoding the decoded dict can change them if the file isn't canonical.
    final infoHash = Uint8List.fromList(
      crypto.sha1.convert(Uint8List.sublistView(bytes, infoSpan.$1, infoSpan.$2)).bytes,
    );

    final name = _sanitize(_text(info['name.utf-8'] ?? info['name']) ?? 'torrent');
    final pieceLength = info['piece length'];
    final piecesRaw = info['pieces'];
    if (pieceLength is! int || pieceLength <= 0 || pieceLength > maxPieceLength) {
      throw FormatException('Invalid piece length $pieceLength');
    }
    if (piecesRaw is! Uint8List || piecesRaw.length % 20 != 0) throw const FormatException('Invalid pieces');

    final pieceHashes = [
      for (var i = 0; i < piecesRaw.length; i += 20) Uint8List.fromList(piecesRaw.sublist(i, i + 20)),
    ];

    final files = <TorrentInfoFile>[];
    final fileList = info['files'];
    var offset = 0;
    if (fileList is List) {
      if (fileList.isEmpty || fileList.length > maxFiles) throw const FormatException('Invalid file list');
      final usedPaths = <String>{};
      for (final f in fileList) {
        if (f is! Map) throw const FormatException('Invalid file entry');
        final length = f['length'];
        final rawPath = f['path.utf-8'] ?? f['path'];
        if (length is! int || length < 0) throw const FormatException('Invalid file length');
        if (rawPath is! List || rawPath.isEmpty) throw const FormatException('Invalid file path');
        final segments = [name, ...rawPath.map((s) => _sanitize(_text(s) ?? '_'))];
        _dedupe(segments, usedPaths);
        files.add(TorrentInfoFile(pathSegments: segments, size: length, offset: offset));
        offset += length;
      }
    } else {
      final length = info['length'];
      if (length is! int || length < 0) throw const FormatException('Single-file torrent has no valid length');
      files.add(TorrentInfoFile(pathSegments: [name], size: length, offset: 0));
      offset = length;
    }

    final expectedPieces = (offset + pieceLength - 1) ~/ pieceLength;
    if (expectedPieces != pieceHashes.length) {
      throw FormatException('Expected $expectedPieces piece hashes, found ${pieceHashes.length}');
    }

    // announce-list is a list of tiers; flatten and dedupe, keeping order.
    final announceUrl = _text(root['announce']);
    final announceList = <String>[];
    void addUrl(String? url) {
      if (url != null && url.isNotEmpty && !announceList.contains(url)) announceList.add(url);
    }

    final tiers = root['announce-list'];
    if (tiers is List) {
      for (final tier in tiers) {
        if (tier is! List) continue;
        for (final u in tier) {
          addUrl(_text(u));
        }
      }
    }
    addUrl(announceUrl);

    final urlList = <String>[];
    final rawUrls = root['url-list'];
    if (rawUrls is List) {
      for (final u in rawUrls) {
        final s = _text(u);
        if (s != null && s.isNotEmpty) urlList.add(s);
      }
    } else if (_text(rawUrls) case final s? when s.isNotEmpty) {
      urlList.add(s);
    }

    return TorrentContent(
      announceUrl: announceUrl,
      announceList: announceList,
      urlList: urlList,
      infoHash: infoHash,
      comment: _text(root['comment']),
      info: TorrentInfo(
        name: name,
        files: files,
        pieceHashes: pieceHashes,
        pieceLength: pieceLength,
        isPrivate: info['private'] == 1,
      ),
    );
  }

  static String? _text(dynamic v) {
    if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
    if (v is String) return v;
    return null;
  }

  static final _reservedWindowsNames = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false);

  /// Makes a path segment safe on every OS: no traversal (`..`), separators,
  /// drive letters, control characters, Windows device names (CON, NUL, ...)
  /// or trailing dots/spaces (which Windows silently strips).
  static String _sanitize(String segment) {
    var s = segment.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return '_';
    if (_reservedWindowsNames.hasMatch(s)) s = '_$s';
    if (s.length > 200) s = s.substring(0, 200);
    return s;
  }

  /// Renames the last segment (`name (2).ext`) if the path, compared
  /// case-insensitively, is already used, so two files never share a path.
  static void _dedupe(List<String> segments, Set<String> used) {
    final original = segments.last;
    final dot = original.lastIndexOf('.');
    final (stem, ext) = dot > 0 ? (original.substring(0, dot), original.substring(dot)) : (original, '');
    for (var n = 2; !used.add(segments.join('/').toLowerCase()); n++) {
      segments[segments.length - 1] = '$stem ($n)$ext';
    }
  }
}

class TorrentContent {
  final String? announceUrl;

  /// All tracker URLs (from `announce-list` tiers and `announce`), deduplicated.
  final List<String> announceList;

  /// BEP 19 web seeds.
  final List<String> urlList;
  final Uint8List infoHash;
  final TorrentInfo info;
  final String? comment;

  TorrentContent({
    required this.announceUrl,
    required this.announceList,
    required this.urlList,
    required this.infoHash,
    required this.info,
    this.comment,
  });

  /// Total size in bytes.
  int get size => info.totalSize;
  String get infoHashHex => TorrentiaUtils.toHex(infoHash);

  @override
  String toString() =>
      'TorrentContent(name: ${info.name}, infoHash: $infoHashHex, size: $size, '
      'pieces: ${info.pieceCount}, trackers: ${announceList.length}, webSeeds: ${urlList.length})';
}

class TorrentInfo {
  final String name;
  final List<TorrentInfoFile> files;
  final List<Uint8List> pieceHashes;
  final int pieceLength;
  final bool isPrivate;

  TorrentInfo({
    required this.name,
    required this.files,
    required this.pieceHashes,
    required this.pieceLength,
    this.isPrivate = false,
  });

  int get pieceCount => pieceHashes.length;
  int get totalSize => files.isEmpty ? 0 : files.last.offset + files.last.size;

  /// Single-file torrents have one file whose path is just the name.
  bool get isMultiFile => files.length > 1 || files.first.pathSegments.length > 1;

  int pieceSize(int index) {
    if (index < pieceCount - 1) return pieceLength;
    return totalSize - pieceLength * (pieceCount - 1);
  }

  /// Inclusive range of pieces covering [file].
  (int, int) piecesForFile(TorrentInfoFile file) {
    final first = file.offset ~/ pieceLength;
    final last = file.size == 0 ? first : (file.offset + file.size - 1) ~/ pieceLength;
    return (first, last);
  }

  @override
  String toString() => 'TorrentInfo(name: $name, files: $files, pieceLength: $pieceLength, pieces: $pieceCount)';
}

class TorrentInfoFile {
  /// Path relative to the download directory, including the torrent name
  /// as the first segment for multi-file torrents.
  final List<String> pathSegments;

  /// Size in bytes.
  final int size;

  /// Byte offset of this file within the torrent's concatenated data.
  final int offset;

  TorrentInfoFile({required this.pathSegments, required this.size, required this.offset});

  String get path => pathSegments.join('/');
  String get name => pathSegments.last;

  @override
  String toString() => 'TorrentInfoFile(path: $path, size: $size)';
}
