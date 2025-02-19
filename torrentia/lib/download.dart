import 'dart:io';
import 'dart:typed_data';

import 'package:torrentia/messages.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';

void download(Peer peer, TorrentContent torrent, List requested) async {
  print("connecting");
  final socket = await Socket.connect(peer.ip, peer.port);
  print("connected");
  socket.add(Messages.buildHandShake(torrent));

  onFullMessage(socket, (msg) => handleMessage(msg, socket, requested));

  // socket.listen((data) {
  //   // final
  // });
}

void onFullMessage(Socket sock, Function(Uint8List buffer) cb) {
  Uint8List savedBuffer = Uint8List(0);
  ByteData bv = ByteData.sublistView(savedBuffer);
  bool handshake = true;

  int calculateMsgLen() {
    return handshake ? bv.getUint8(0) + 49 : bv.getUint32(0) + 4;
  }

  sock.listen((data) {
    savedBuffer = Uint8List.fromList(savedBuffer)..addAll(data);

    while (savedBuffer.length >= 4 && savedBuffer.length >= calculateMsgLen()) {
      cb(savedBuffer.sublist(0, calculateMsgLen()));
      savedBuffer = savedBuffer.sublist(calculateMsgLen());
      handshake = false;
    }
  }, onDone: () => print("Done listening"));
}

void handleMessage(Uint8List message, Socket sock, List requested) {
  if (isHandshake(message)) {
    sock.add(Messages.buildInterested());
  } else {
    final msg = Messages.parseMessage(message);

    if (msg == null) return;

    switch (msg.id) {
      case 0:
        handleChoke();
        break;
      case 1:
        handleUnchoke();
        break;
      case 4:
        handleHave(msg.payload, sock, requested);
        break;
      case 5:
        handleBitfield(msg.payload);
        break;
      case 7:
        handlePiece(msg.payload);
        break;
    }
  }
}

void handleChoke() {}

void handleUnchoke() {}

void handleHave(Uint8List payload, Socket sock, List requested) {
  final bv = ByteData.sublistView(payload);
  final index = bv.getUint32(0);
  if (requested[index] == false) {
    // sock.add(Messages.buildRequest(index, ));
  }
  requested[index] = true;
}

void handleBitfield(dynamic payload) {}

void handlePiece(dynamic payload) {}

bool isHandshake(Uint8List msg) {
  final protocolString = String.fromCharCodes(msg.sublist(1, 20));
  return msg.length == msg[0] + 49 && protocolString == "BitTorrent protocol";
}
