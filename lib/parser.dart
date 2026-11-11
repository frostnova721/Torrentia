import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:torrentia/bencode.dart';

class TrackerException implements Exception {
  final String message;
  TrackerException(this.message);

  @override
  String toString() => 'TrackerException: $message';
}

/// Parses a bencoded HTTP tracker response.
AnnounceResponse parseHttpAnnounceResponse(Uint8List body) {
  final dynamic decoded;
  try {
    decoded = bdecode(body).value;
  } on BencodeException catch (e) {
    throw TrackerException('Malformed response: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) throw TrackerException('Response is not a dictionary');

  final failure = decoded['failure reason'];
  if (failure != null) throw TrackerException(_text(failure));

  final peers = <Peer>[];
  final rawPeers = decoded['peers'];
  if (rawPeers is Uint8List) {
    peers.addAll(parseCompactPeers(rawPeers));
  } else if (rawPeers is List) {
    // Non-compact form: list of {ip, port, peer id} dictionaries.
    for (final p in rawPeers) {
      if (p is Map && p['ip'] != null && p['port'] is int) {
        peers.add(Peer(ip: _text(p['ip']), port: p['port'] as int));
      }
    }
  }
  final rawPeers6 = decoded['peers6'];
  if (rawPeers6 is Uint8List) peers.addAll(parseCompactPeers6(rawPeers6));

  return AnnounceResponse(
    interval: (decoded['min interval'] ?? decoded['interval'] ?? 1800) as int,
    leechers: (decoded['incomplete'] ?? 0) as int,
    seeders: (decoded['complete'] ?? 0) as int,
    peers: peers,
    warning: decoded['warning message'] == null ? null : _text(decoded['warning message']),
  );
}

/// Parses a UDP connect response (BEP 15) and checks it answers our request.
ConnectionResponse parseConnResponse(Uint8List response, {required int transactionId}) {
  _checkUdpHeader(response, 0, transactionId, minLength: 16);
  final bytes = ByteData.sublistView(response);
  return ConnectionResponse(
    transactionId: transactionId,
    connectionId: bytes.getUint64(8, Endian.big),
  );
}

/// Parses a UDP announce response (BEP 15).
///
/// Layout: action(4) transaction_id(4) interval(4) leechers(4) seeders(4) peers(6*n)
AnnounceResponse parseUdpAnnounceResponse(Uint8List response, {required int transactionId}) {
  _checkUdpHeader(response, 1, transactionId, minLength: 20);
  final bytes = ByteData.sublistView(response);
  return AnnounceResponse(
    interval: bytes.getUint32(8),
    leechers: bytes.getUint32(12),
    seeders: bytes.getUint32(16),
    peers: parseCompactPeers(Uint8List.sublistView(response, 20)),
  );
}

void _checkUdpHeader(Uint8List response, int expectedAction, int transactionId, {required int minLength}) {
  if (response.length < 8) throw TrackerException('Response too short: ${response.length} bytes');
  final bytes = ByteData.sublistView(response);
  final action = bytes.getUint32(0);
  final tid = bytes.getUint32(4);
  if (tid != transactionId) throw TrackerException('Transaction id mismatch');
  if (action == 3) throw TrackerException(_text(Uint8List.sublistView(response, 8)));
  if (action != expectedAction) throw TrackerException('Unexpected action $action (wanted $expectedAction)');
  if (response.length < minLength) throw TrackerException('Response too short: ${response.length} bytes');
}

/// Compact IPv4 peer list: 4 bytes IP + 2 bytes port, big-endian.
List<Peer> parseCompactPeers(Uint8List data) {
  final peers = <Peer>[];
  for (var i = 0; i + 6 <= data.length; i += 6) {
    final ip = '${data[i]}.${data[i + 1]}.${data[i + 2]}.${data[i + 3]}';
    final port = (data[i + 4] << 8) | data[i + 5];
    if (port != 0) peers.add(Peer(ip: ip, port: port));
  }
  return peers;
}

/// Compact IPv6 peer list: 16 bytes IP + 2 bytes port.
List<Peer> parseCompactPeers6(Uint8List data) {
  final peers = <Peer>[];
  for (var i = 0; i + 18 <= data.length; i += 18) {
    final ip = InternetAddress.fromRawAddress(Uint8List.fromList(data.sublist(i, i + 16))).address;
    final port = (data[i + 16] << 8) | data[i + 17];
    if (port != 0) peers.add(Peer(ip: ip, port: port));
  }
  return peers;
}

String _text(dynamic v) => v is Uint8List ? utf8.decode(v, allowMalformed: true) : v.toString();

class AnnounceResponse {
  /// Seconds to wait before re-announcing.
  final int interval;
  final int leechers;
  final int seeders;
  final List<Peer> peers;
  final String? warning;

  AnnounceResponse({
    required this.interval,
    required this.leechers,
    required this.seeders,
    required this.peers,
    this.warning,
  });

  @override
  String toString() =>
      'AnnounceResponse(interval: $interval, leechers: $leechers, seeders: $seeders, peers: ${peers.length})';
}

class Peer {
  final String ip;
  final int port;

  Peer({required this.ip, required this.port});

  String get key => '$ip:$port';

  @override
  bool operator ==(Object other) => other is Peer && other.ip == ip && other.port == port;

  @override
  int get hashCode => Object.hash(ip, port);

  @override
  String toString() => ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
}

class ConnectionResponse {
  final int transactionId;
  final int connectionId;

  ConnectionResponse({required this.transactionId, required this.connectionId});

  @override
  String toString() => 'ConnectionResponse(transactionId: $transactionId, connectionId: $connectionId)';
}
