import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:torrentia/network/builders.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

/// Largest tracker response we accept (a few thousand peers fit easily).
const maxTrackerResponseBytes = 2 * 1024 * 1024;

/// Whether this client can talk to the tracker at [announceUrl].
bool isSupportedTracker(String announceUrl) {
  final scheme = Uri.tryParse(announceUrl)?.scheme;
  return scheme == 'http' || scheme == 'https' || scheme == 'udp';
}

/// Announces to a single tracker. Throws [TrackerException] on failure.
Future<AnnounceResponse> sendAnnounceRequest(
  String announceUrl,
  TorrentContent torrent,
  AnnounceParams params,
) async {
  final uri = Uri.parse(announceUrl);
  switch (uri.scheme) {
    case 'http':
    case 'https':
      return sendHttpRequest(uri, torrent, params);
    case 'udp':
      return sendUdpRequest(uri, torrent, params);
    default:
      throw UnsupportedError('Tracker protocol "${uri.scheme}" is not supported');
  }
}

Future<AnnounceResponse> sendHttpRequest(Uri uri, TorrentContent torrent, AnnounceParams params) async {
  final requestUri = buildHttpConnectionRequest(trackerUrl: uri.toString(), torrent: torrent, params: params);
  final client = http.Client();
  try {
    await NetworkPolicy.checkHost(requestUri.host);
    final req = http.Request('GET', requestUri)..maxRedirects = 3;
    final res = await client.send(req).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw TrackerException('HTTP ${res.statusCode}');
    final body = await readLimited(res.stream, maxTrackerResponseBytes).timeout(const Duration(seconds: 15));
    return parseHttpAnnounceResponse(body);
  } on TrackerException {
    rethrow;
  } on TimeoutException {
    throw TrackerException('HTTP request timed out');
  } catch (e) {
    throw TrackerException('HTTP request failed: $e');
  } finally {
    client.close();
  }
}

final _random = Random.secure();

/// BEP 15 UDP announce: connect, then announce, both on the same socket
/// (trackers may tie the connection id to the source address).
/// Retries with a growing timeout.
Future<AnnounceResponse> sendUdpRequest(
  Uri uri,
  TorrentContent torrent,
  AnnounceParams params, {
  int attempts = 3,
  Duration baseTimeout = const Duration(seconds: 4),
}) async {
  if (!uri.hasPort) throw TrackerException('UDP tracker URL has no port');

  final List<InternetAddress> addresses;
  try {
    addresses = await InternetAddress.lookup(uri.host).timeout(const Duration(seconds: 10));
  } on Exception catch (e) {
    throw TrackerException('DNS lookup failed for ${uri.host}: $e');
  }
  if (addresses.isEmpty) throw TrackerException('DNS lookup returned no addresses for ${uri.host}');
  final address = addresses.firstWhere(
    (a) => a.type == InternetAddressType.IPv4,
    orElse: () => addresses.first,
  );
  if (!NetworkPolicy.isAllowed(address)) {
    throw TrackerException('Refusing to contact non-public tracker address ${address.address}');
  }

  final socket = await RawDatagramSocket.bind(
    address.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
    0,
  );
  final datagrams = StreamController<Uint8List>.broadcast();
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d != null && d.address == address) datagrams.add(d.data);
  });

  Future<Uint8List> exchange(Uint8List packet, int tid, Duration timeout) async {
    final reply = Completer<Uint8List>();
    final sub = datagrams.stream.listen((d) {
      if (!reply.isCompleted && d.length >= 8 && ByteData.sublistView(d).getUint32(4) == tid) {
        reply.complete(d);
      }
    });
    try {
      socket.send(packet, address, uri.port);
      return await reply.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  try {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final timeout = baseTimeout * (1 << attempt);
      try {
        final connTid = randomTransactionId();
        final connReply = await exchange(buildConnReq(connTid), connTid, timeout);
        final conn = parseConnResponse(connReply, transactionId: connTid);

        final annTid = randomTransactionId();
        final annReq = buildAnnounceRequest(
          connId: conn.connectionId,
          transactionId: annTid,
          torrent: torrent,
          params: params,
          key: _random.nextInt(1 << 32),
        );
        final annReply = await exchange(annReq, annTid, timeout);
        return parseUdpAnnounceResponse(annReply, transactionId: annTid);
      } on TimeoutException catch (e) {
        lastError = e;
      }
    }
    throw TrackerException('No response after $attempts attempts ($lastError)');
  } finally {
    socket.close();
    await datagrams.close();
  }
}
