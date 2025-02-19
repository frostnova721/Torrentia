import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:b_encode_decode/b_encode_decode.dart' as Bencode;

class Reader {
  Future<TorrentContent> readFromFile(String path) async {
    final file = File(path);
    final content = await file.readAsBytes();
    final Map<String, dynamic> bencoded = Bencode.decode(content, stringEncoding: "utf8");

    final announceUrl = utf8.decode(bencoded['announce']);

    final Map<String, dynamic> info = bencoded['info'];
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

    // print(announceUrl);
    return TorrentContent(
      announceUrl: announceUrl,
      infoHash: infoHash,
      size: size,
    );
  }
}

class TorrentContent {
  final String announceUrl;
  final Uint8List infoHash;
  final int size;

  TorrentContent({
    required this.announceUrl,
    required this.infoHash,
    required this.size,
  });
}
