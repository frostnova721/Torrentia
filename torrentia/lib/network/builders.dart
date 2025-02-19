import 'dart:math';
import 'dart:typed_data';

import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

Uint8List buildConnReq() {
  final buffer = Uint8List(16);
  final byteView = ByteData.sublistView(buffer);

  //conn id
  byteView.setUint32(0, 0x417);
  byteView.setUint32(4, 0x27101980);

  byteView.setUint32(8, 0);

  final random = Random.secure();
  for (int i = 12; i < 16; i++) {
    buffer[i] = random.nextInt(256);
  }

  return buffer;
}

Uint8List buildAnnounceRequest({
  required Uint8List connId,
  required TorrentContent torrent,
  int port = 6881,
}) {
  final buffer = Uint8List(98);
  final byteView = ByteData.sublistView(buffer);

  buffer.setRange(0, 8, connId);
  byteView.setUint32(8, 1); //action

  final rand = Random.secure();

  for (int i = 12; i < 16; i++) {
    buffer[i] = rand.nextInt(256); //transaction id
  }

  buffer.setRange(16, 36, torrent.infoHash); //info hash

  buffer.setRange(36, 56, TorrentiaUtils.generateId()); //peer id

  buffer.setRange(56, 64, Uint16List(8)); //downloaded

  byteView.setUint32(64,torrent.size); //left

  buffer.setRange(72, 80, Uint8List(8)); //uploaded

  byteView.setUint32(80, 0); //event

  byteView.setUint32(84, 0); //ip

  for (int i = 88; i < 92; i++) {
    buffer[i] = rand.nextInt(256); //key
  }

  byteView.setInt32(92, -1); //num want

  byteView.setUint16(96, port);

  return buffer;
}

Uri buildHttpConnectionRequest({
  required String trackerUrl,
  required TorrentContent torrent,
  int port = 6881,
}) {
  final infoHash = torrent.infoHash;
  final peerId = TorrentiaUtils.generateId();
  final port = 6881;
  final uploaded = 0;
  final downloaded = 0;
  final left = torrent.size;

  final String encodedInfoHash = _urlEncodeInfoHash(infoHash);

  // Manually construct the query string
  final String query = [
    'peer_id=${_urlEncodeInfoHash(peerId)}',
    'port=$port',
    'uploaded=$uploaded',
    'downloaded=$downloaded',
    'left=$left',
    'compact=1',
    'event=started',
    'info_hash=$encodedInfoHash',
  ].join('&');

  try {
    final Uri baseUri = Uri.parse(trackerUrl);
    final Uri finalUri = Uri(
      scheme: baseUri.scheme,
      host: baseUri.host,
      port: baseUri.port,
      path: baseUri.path,
      query: query,
    );

    print("Built Uri: $finalUri");
    return finalUri;
  } catch (e) {
    print(e);
    throw Exception("Failed to build URI");
  }
}

String _urlEncodeInfoHash(Uint8List infoHash) {
  return infoHash.map((byte) => '%${byte.toRadixString(16).padLeft(2, '0')}').join();
}
