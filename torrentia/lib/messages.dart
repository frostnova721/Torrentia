import 'dart:convert';
import 'dart:typed_data';

import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

class Messages {
  static Uint8List buildHandShake(TorrentContent torrent) {
    final handshake = BytesBuilder();
  handshake.addByte(19); // Protocol length
  handshake.add(utf8.encode("BitTorrent protocol"));
  handshake.add(Uint8List(8)); // Reserved bytes
  handshake.add(torrent.infoHash);
  handshake.add(TorrentiaUtils.generateId());

  return handshake.toBytes();
  }

  static Uint8List buildUnchoke() {
    final buffer = Uint8List(5);
    final byteView = ByteData.sublistView(buffer);

    byteView.setUint32(0, 1);
    byteView.setUint8(4, 1);

    return buffer;
  }

  static Uint8List buildInterested() {
    final buffer = Uint8List(5);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 1);
    bv.setUint8(4, 2);

    return buffer;
  }

  static Uint8List buildUnInterested() {
    final buffer = Uint8List(5);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 1);
    bv.setUint8(4, 3);

    return buffer;
  }

  static Uint8List buildHave(Uint8List payload) {
    final buffer = Uint8List(9);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 5);
    bv.setUint8(4, 4);
    buffer.setRange(5, payload.length + 5, payload);

    return buffer;
  }

  static Uint8List buildBitField(Uint8List bitfield) {
    final buffer = Uint8List(14);
    final bv = ByteData.sublistView(buffer);

    buffer.setRange(0, 4, bitfield);

    bv.setUint8(4, 5);
    buffer.setRange(5, bitfield.length + 5, bitfield);

    return buffer;
  }

  static Uint8List buildRequest(int index, int begin, int length) {
    final buffer = Uint8List(17);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 13);
    bv.setUint8(4, 6);
    bv.setUint32(5, index);
    bv.setUint32(9, begin);
    bv.setUint32(13, length);

    return buffer;
  }

  static Uint8List buildPiece(int index, int begin, Uint8List block) {
    final buffer = Uint8List(block.length + 13);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, block.length + 9); //len

    bv.setUint8(4, 7); //id

    bv.setUint32(5, index); //index of piece

    bv.setUint32(9, begin);

    buffer.setRange(13, block.length + 13, block);

    return buffer;
  }

  static Uint8List buildCancel(int index, int begin, int length) {
    final buffer = Uint8List(17);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 13); //length
    bv.setUint8(4, 8); //id
    bv.setUint32(5, index); //piece index
    bv.setUint32(9, begin); //begin
    bv.setUint32(13, length); //length

    return buffer;
  }

  static Uint8List buildPort(Uint8List payload) {
    final buffer = Uint8List(7);
    final bv = ByteData.sublistView(buffer);

    bv.setUint32(0, 3);
    bv.setUint8(4, 9); //id

    buffer.setRange(5, 7, payload); //listen port

    return buffer;
  }

  static ResponseMessage? parseMessage(Uint8List message) {
    final bv = ByteData.sublistView(message);
    final id = message.length > 4 ? bv.getInt8(4) : null;
    Uint8List? payload = message.length > 5 ? message.sublist(5) : null;
    if (payload == null || id == null) return null;
    Map<String, dynamic>? payloadmap;
    if (id == 6 || id == 7 || id == 8) {
      final rest = payload.sublist(8);
      final payloadBv = ByteData.sublistView(payload);
      payloadmap = {
        'index': payloadBv.getInt32(0),
        'begin': payloadBv.getInt32(4),
      };

      payloadmap[id == 7 ? 'block' : 'length'] = rest;
    }

    return ResponseMessage(size: bv.getInt32(0), id: id, payload: payloadmap ?? payload);
  }
}

class ResponseMessage {
  final int size;
  final int id;
  final dynamic payload;

  ResponseMessage({
    required this.size,
    required this.id,
    required this.payload,
  });
}
