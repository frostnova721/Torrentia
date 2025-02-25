import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:torrentia/network/builders.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';

Future<AnnounceResponse> sendAnnounceRequest(TorrentContent torrent) async {
  final uri = Uri.parse(torrent.announceUrl);

  final protocol = uri.scheme;

  print(protocol);

  switch (protocol) {
    case "http":
      return await sendHttpRequest(uri, torrent);
    case "udp":
      return await sendUdpRequest(uri, torrent);
    default:
      throw UnimplementedError(
          "The Implementation for \"$protocol\" has not been done yet");
  }
}

// final client = http.Client();

Future<dynamic> sendHttpRequest(Uri uri, TorrentContent torrent) async {
  final requestUri =
      buildHttpConnectionRequest(trackerUrl: uri.toString(), torrent: torrent);
  final res = await http.get(requestUri);
  final resBytes = res.bodyBytes;

  final parsedResponse = parseAnnounceStringResponse(resBytes);

  print(parsedResponse.toString());

  return parsedResponse;
}

Future<dynamic> sendUdpRequest(Uri uri, TorrentContent content) async {
  final reqData = buildConnReq();

  const localPort = 6771;

  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
  s.broadcastEnabled = true;

  final iadr = await InternetAddress.lookup(uri.host);
  print(iadr);
  print(content.infoHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join(''));
  if (iadr.isEmpty) {
    print("Address lookup failed.");
  }

  final sender = s.send(reqData,
      iadr.firstWhere((it) => it.type == InternetAddressType.IPv4), uri.port);
  print("Sent bytes: $sender");

  Completer<Uint8List?> completer = Completer();
  s.listen((RawSocketEvent event) {
    print(event);
    if (event == RawSocketEvent.read) {
      final res = s.receive();
      print(res);
      if (res != null) {
        completer.complete(res.data);
        s.close();
      }
    }
  });
  await completer.future.timeout(Duration(seconds: 15), onTimeout: () async {
    s.close();
    print("Connection timed out.");
    return null;
  });
  // s.close();

  // final res = sender.send(reqData, Endpoint.any(port: 65001));
  // final announceReq = buildAnnounceRequest(torrent: content, connId: rdbv.get);
}
