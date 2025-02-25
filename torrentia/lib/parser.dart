// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart';

AnnounceResponse parseAnnounceStringResponse(Uint8List resp) {
  final Map<String, dynamic> decoded = decode(resp);
  print(decoded);

  return AnnounceResponse(
    action: 0,
    transactionId: 0,
    leechers: decoded['incomplete'] ?? 0,
    seeders: decoded['complete'] ?? 0,
    peers: _parsePeers(decoded['peers'] as Uint8List),
  );
}

AnnounceResponse parseAnnounceBufferResponse(Uint8List resp) {
  final ByteData byteData = ByteData.sublistView(resp);

  // Make sure we have at least 20 bytes (minimum size for header)
  if (resp.length < 20) {
    throw Exception('Response too short: ${resp.length} bytes');
  }

  final action = byteData.getInt32(0, Endian.big); // Changed to getInt32
  final transactionId = byteData.getInt32(4, Endian.big);
  final leechers = byteData.getInt32(8, Endian.big);
  final seeders = byteData.getInt32(12, Endian.big);

  // Add validation
  if (action != 0 && action != 1) {
    throw Exception('Invalid action value: $action');
  }

  // The remaining part of the response is the peers data
  final peersData = resp.sublist(20);
  final peers = _parsePeers(peersData);

  return AnnounceResponse(
    action: action,
    transactionId: transactionId,
    leechers: leechers,
    seeders: seeders,
    peers: peers,
  );
}

List<Peer> _parsePeers(Uint8List peersData) {
  final List<Peer> peers = [];
  for (int i = 0; i < peersData.length; i += 6) {
    if (i + 6 > peersData.length) break; // Prevent overflow

    final ipBytes = peersData.sublist(i, i + 4);
    final portBytes = peersData.sublist(i + 4, i + 6);

    // Proper IP address formatting
    final ip = ipBytes.map((b) => b.toString()).join('.');
    final portRaw1 = portBytes[0];
    final portRaw2 = portBytes[1];
    final port = ((portRaw1 & 0xFF) << 8) | (portRaw2 & 0xFF);

    peers.add(Peer(ip: ip, port: port));
  }
  return peers;
}

ConnectionResponse parseConnResponse(Uint8List response) {
  if (response.length < 16) {
    throw Exception(
        "Expected Length Of 16 Bytes. Recieved ${response.length} Bytes");
  }

  final bytes = ByteData.sublistView(response);
  return ConnectionResponse(
    action: bytes.getUint32(0),
    transactionId: bytes.getUint32(4),
    connectionId: response.sublist(8),
  );
}

class AnnounceResponse {
  final int action;
  final int transactionId;
  final int leechers;
  final int seeders;
  final List<Peer> peers;

  AnnounceResponse({
    required this.action,
    required this.transactionId,
    required this.leechers,
    required this.seeders,
    required this.peers,
  });

  @override
  String toString() {
    return 'AnnounceResponse(action: $action, transactionId: $transactionId, leechers: $leechers, seeders: $seeders, peers: $peers)';
  }
}

class Peer {
  final String ip;
  final int port;

  Peer({required this.ip, required this.port});

  @override
  String toString() => 'Peer(ip: $ip, port: $port)';
}

class ConnectionResponse {
  final int action;
  final int transactionId;
  final dynamic connectionId;

  ConnectionResponse({
    required this.action,
    required this.transactionId,
    required this.connectionId,
  });

  @override
  String toString() =>
      'ConnectionResponse(action: $action, transactionId: $transactionId, connectionId: $connectionId)';
}
