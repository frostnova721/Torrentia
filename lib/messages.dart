import 'dart:typed_data';

/// Peer wire protocol message ids (BEP 3).
abstract final class MessageId {
  static const keepAlive = -1;
  static const choke = 0;
  static const unchoke = 1;
  static const interested = 2;
  static const notInterested = 3;
  static const have = 4;
  static const bitfield = 5;
  static const request = 6;
  static const piece = 7;
  static const cancel = 8;
  static const port = 9;
  static const extended = 20;
}

const protocolString = 'BitTorrent protocol';
const handshakeLength = 68;

class Handshake {
  final Uint8List reserved;
  final Uint8List infoHash;
  final Uint8List peerId;

  Handshake({required this.reserved, required this.infoHash, required this.peerId});

  /// Parses a 68-byte handshake, or returns null if it isn't one.
  static Handshake? parse(Uint8List data) {
    if (data.length < handshakeLength || data[0] != 19) return null;
    if (String.fromCharCodes(data.sublist(1, 20)) != protocolString) return null;
    return Handshake(
      reserved: Uint8List.fromList(data.sublist(20, 28)),
      infoHash: Uint8List.fromList(data.sublist(28, 48)),
      peerId: Uint8List.fromList(data.sublist(48, 68)),
    );
  }
}

class Messages {
  static Uint8List buildHandShake(Uint8List infoHash, Uint8List peerId) {
    final b = BytesBuilder(copy: false)
      ..addByte(19)
      ..add(protocolString.codeUnits)
      ..add(Uint8List(8)) // reserved: no extensions
      ..add(infoHash)
      ..add(peerId);
    return b.toBytes();
  }

  static Uint8List buildKeepAlive() => Uint8List(4);

  static Uint8List _simple(int id) {
    final buffer = Uint8List(5);
    ByteData.sublistView(buffer)
      ..setUint32(0, 1)
      ..setUint8(4, id);
    return buffer;
  }

  static Uint8List buildChoke() => _simple(MessageId.choke);
  static Uint8List buildUnchoke() => _simple(MessageId.unchoke);
  static Uint8List buildInterested() => _simple(MessageId.interested);
  static Uint8List buildNotInterested() => _simple(MessageId.notInterested);

  static Uint8List buildHave(int pieceIndex) {
    final buffer = Uint8List(9);
    ByteData.sublistView(buffer)
      ..setUint32(0, 5)
      ..setUint8(4, MessageId.have)
      ..setUint32(5, pieceIndex);
    return buffer;
  }

  static Uint8List buildBitField(Uint8List bitfield) {
    final buffer = Uint8List(5 + bitfield.length);
    ByteData.sublistView(buffer)
      ..setUint32(0, 1 + bitfield.length)
      ..setUint8(4, MessageId.bitfield);
    buffer.setRange(5, buffer.length, bitfield);
    return buffer;
  }

  static Uint8List buildRequest(int index, int begin, int length) =>
      _triple(MessageId.request, index, begin, length);

  static Uint8List buildCancel(int index, int begin, int length) =>
      _triple(MessageId.cancel, index, begin, length);

  static Uint8List _triple(int id, int index, int begin, int length) {
    final buffer = Uint8List(17);
    ByteData.sublistView(buffer)
      ..setUint32(0, 13)
      ..setUint8(4, id)
      ..setUint32(5, index)
      ..setUint32(9, begin)
      ..setUint32(13, length);
    return buffer;
  }

  static Uint8List buildPiece(int index, int begin, Uint8List block) {
    final buffer = Uint8List(13 + block.length);
    ByteData.sublistView(buffer)
      ..setUint32(0, 9 + block.length)
      ..setUint8(4, MessageId.piece)
      ..setUint32(5, index)
      ..setUint32(9, begin);
    buffer.setRange(13, buffer.length, block);
    return buffer;
  }

  static Uint8List buildPort(int port) {
    final buffer = Uint8List(7);
    ByteData.sublistView(buffer)
      ..setUint32(0, 3)
      ..setUint8(4, MessageId.port)
      ..setUint16(5, port);
    return buffer;
  }

  /// Parses one length-prefixed frame (including its 4-byte length).
  static PeerMessage parseMessage(Uint8List frame) {
    if (frame.length < 4) throw const FormatException('Frame shorter than its length prefix');
    final view = ByteData.sublistView(frame);
    final length = view.getUint32(0);
    if (frame.length != length + 4) throw FormatException('Frame length mismatch: $length vs ${frame.length - 4}');
    if (length == 0) return PeerMessage(MessageId.keepAlive, Uint8List(0));
    return PeerMessage(frame[4], Uint8List.sublistView(frame, 5));
  }
}

class PeerMessage {
  final int id;
  final Uint8List payload;

  PeerMessage(this.id, this.payload);

  ByteData get _view => ByteData.sublistView(payload);

  /// For `have`.
  int get haveIndex => _view.getUint32(0);

  /// For `request` / `cancel`: (index, begin, length).
  (int, int, int) get requestFields => (_view.getUint32(0), _view.getUint32(4), _view.getUint32(8));

  /// For `piece`: (index, begin, block).
  (int, int, Uint8List) get pieceFields =>
      (_view.getUint32(0), _view.getUint32(4), Uint8List.sublistView(payload, 8));

  @override
  String toString() => 'PeerMessage(id: $id, payload: ${payload.length} bytes)';
}
