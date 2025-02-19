import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart' as Bencode;
import 'package:crypto/crypto.dart' as crypto;

class Reader {
  Future<TorrentContent> readFromFile(String path) async {
    final file = File(path);
    final content = await file.readAsBytes();
    final Map<String, dynamic> bencoded =
        Bencode.decode(content, stringEncoding: "utf8");

    final announceUrl = utf8.decode(bencoded['announce']);

    final Map<String, dynamic> info = bencoded['info'];
    // print(info);

    final List<dynamic> files = info['files'];

    final List<TorrentInfoFile> fileList = [];

    files.forEach((it) {
      final List<dynamic> path = it['path'];
      final length = it['length'];

      final file = (utf8.decode(path[0]));

      fileList.add(TorrentInfoFile(size: length, path: file));
    });

// bencoded stuff contains (! means parsed):
// - announce !
// - announce-list !
// - comment
// - creation date
// - created by
// - info !
// - encoding
// - url-list

// info contains:
//     files !
//    name !
//    piece length !
//    pieces !

    final name = utf8.decode(info['name']);

    final List<String> announceList = [];

    final annlist = bencoded['announce-list'];
    annlist.forEach((it) => announceList.add(utf8.decode(it[0])));

    final List<String> urlList = [];
    bencoded['url-list'].forEach((it) => urlList.add(utf8.decode(it)));

    final int pieceLength = info['piece length'];

    final infoClassed = TorrentInfo(
        files: fileList,
        name: name,
        pieces: info['pieces'],
        pieceLength: pieceLength);

    final infoEncoded = Bencode.encode(info);
    final infoHash = Uint8List.fromList(crypto.sha1.convert(infoEncoded).bytes);

    int size;

    // Check if files exist and sum their lengths
    if (bencoded['info']['files'] != null) {
      size = 0;
      for (final file in bencoded['info']['files']) {
        size += file['length'] as int;
      }
    } else {
      size = bencoded['info']['length'];
    }

    return TorrentContent(
      announceUrl: announceUrl,
      infoHash: infoHash,
      size: size,
      announceList: announceList,
      info: infoClassed,
    );
  }
}

class TorrentContent {
  final String announceUrl;
  final List<String> announceList;
  final Uint8List infoHash;
  final TorrentInfo info;
  final int size;

  TorrentContent({
    required this.announceUrl,
    required this.infoHash,
    required this.size,
    required this.info,
    required this.announceList,
  });

  @override
  String toString() {
    return 'TorrentContent(announceUrl: $announceUrl, announceList: $announceList, infoHash: $infoHash, info: $info, size: $size)';
  }
}

class TorrentInfo {
  final List<TorrentInfoFile> files;
  final String name;
  final dynamic pieces;
  final int pieceLength;

  TorrentInfo(
      {required this.files,
      required this.name,
      required this.pieces,
      required this.pieceLength});

  @override
  String toString() {
    return 'TorrentInfo(files: $files, name: $name, pieces: ${pieces.toString().length > 100 ? 'long stuff :)' : '$pieces'}, pieceLength: $pieceLength)';
  }
}

class TorrentInfoFile {
  final String path;
  final int size; // in bits

  TorrentInfoFile({required this.path, required this.size});

  @override
  String toString() => 'TorrentInfoFile(path: $path, size: $size)';
}
