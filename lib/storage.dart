import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

/// A contiguous part of a torrent byte range that lives in one file.
class FileSlice {
  final int fileIndex;
  final int fileOffset;
  final int length;

  /// Offset of this slice within the requested range.
  final int rangeOffset;

  FileSlice(this.fileIndex, this.fileOffset, this.length, this.rangeOffset);
}

/// Reads and writes torrent data to disk. All disk I/O is serialized, because
/// a [RandomAccessFile] can't have more than one pending operation at a time.
class Storage {
  final TorrentContent torrent;
  final String rootDir;

  /// Verified pieces kept in memory so streaming reads rarely touch disk.
  final int cacheBytes;

  final _handles = <int, RandomAccessFile>{};
  final _cache = <int, Uint8List>{}; // insertion-ordered: oldest first
  int _cachedBytes = 0;
  Future<void> _tail = Future.value();

  Storage(this.torrent, this.rootDir, {this.cacheBytes = 64 * 1024 * 1024});

  TorrentInfo get _info => torrent.info;

  String filePath(int fileIndex) =>
      [rootDir, ..._info.files[fileIndex].pathSegments].join(Platform.pathSeparator);

  /// Splits the torrent byte range [offset, offset+length) across files.
  List<FileSlice> slices(int offset, int length) {
    final result = <FileSlice>[];
    final end = offset + length;
    final files = _info.files;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final fEnd = f.offset + f.size;
      if (fEnd <= offset || f.size == 0) continue;
      if (f.offset >= end) break;
      final start = offset > f.offset ? offset : f.offset;
      final stop = end < fEnd ? end : fEnd;
      result.add(FileSlice(i, start - f.offset, stop - start, start - offset));
    }
    return result;
  }

  Future<T> _locked<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<RandomAccessFile> _handle(int fileIndex) async {
    final existing = _handles[fileIndex];
    if (existing != null) return existing;
    final file = File(filePath(fileIndex));
    await file.parent.create(recursive: true);
    // append mode = read/write without truncating; positions are set explicitly.
    final raf = await file.open(mode: FileMode.append);
    return _handles[fileIndex] = raf;
  }

  Future<void> writePiece(int index, Uint8List data) {
    _cachePut(index, data);
    return _locked(() async {
      for (final s in slices(index * _info.pieceLength, data.length)) {
        final raf = await _handle(s.fileIndex);
        await raf.setPosition(s.fileOffset);
        await raf.writeFrom(data, s.rangeOffset, s.rangeOffset + s.length);
      }
    });
  }

  /// Reads a torrent byte range. Callers must only read pieces that are complete.
  Future<Uint8List> read(int offset, int length) {
    final pieceLength = _info.pieceLength;
    final piece = offset ~/ pieceLength;
    final cached = _cache[piece];
    if (cached != null && offset + length <= piece * pieceLength + cached.length) {
      final start = offset - piece * pieceLength;
      return Future.value(Uint8List.sublistView(cached, start, start + length));
    }
    return _locked(() async {
      final out = Uint8List(length);
      for (final s in slices(offset, length)) {
        final raf = await _handle(s.fileIndex);
        await raf.setPosition(s.fileOffset);
        var done = 0;
        while (done < s.length) {
          final n = await raf.readInto(out, s.rangeOffset + done, s.rangeOffset + s.length);
          if (n == 0) throw FileSystemException('Unexpected end of file', filePath(s.fileIndex));
          done += n;
        }
      }
      return out;
    });
  }

  Future<Uint8List> readPiece(int index) => read(index * _info.pieceLength, _info.pieceSize(index));

  void _cachePut(int index, Uint8List data) {
    if (data.length > cacheBytes) return;
    final old = _cache.remove(index);
    if (old != null) _cachedBytes -= old.length;
    _cache[index] = data;
    _cachedBytes += data.length;
    while (_cachedBytes > cacheBytes && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      _cachedBytes -= _cache.remove(oldest)!.length;
    }
  }

  /// Hash-checks data already on disk (resume). Only pieces whose files exist
  /// and are long enough are read. Returns the indexes of valid pieces.
  Future<List<int>> verifyExisting({bool Function(int piece)? include}) async {
    final lengths = <int, int>{};
    for (var i = 0; i < _info.files.length; i++) {
      final f = File(filePath(i));
      if (await f.exists()) lengths[i] = await f.length();
    }
    if (lengths.isEmpty) return const [];

    final valid = <int>[];
    var checked = 0;
    for (var p = 0; p < _info.pieceCount; p++) {
      if (include != null && !include(p)) continue;
      final pieceSlices = slices(p * _info.pieceLength, _info.pieceSize(p));
      final onDisk = pieceSlices.every((s) => (lengths[s.fileIndex] ?? -1) >= s.fileOffset + s.length);
      if (!onDisk) continue;
      if (hashMatches(await readPiece(p), _info.pieceHashes[p])) valid.add(p);
      if (++checked % 200 == 0) Log.info('Checked $checked existing pieces...');
    }
    return valid;
  }

  Future<void> close() => _locked(() async {
        for (final raf in _handles.values) {
          await raf.close();
        }
        _handles.clear();
        _cache.clear();
        _cachedBytes = 0;
      });
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether [data]'s SHA-1 equals [expected].
bool hashMatches(Uint8List data, Uint8List expected) => _equal(crypto.sha1.convert(data).bytes, expected);
