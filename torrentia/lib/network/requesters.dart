import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:torrentia/network/builders.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';

Future<AnnounceResponse?> sendAnnounceRequest(String announceUrl, TorrentContent torrent) async {
  final uri = Uri.parse(announceUrl);

  final protocol = uri.scheme;

  switch (protocol) {
    case "http":
      return await sendHttpRequest(uri, torrent);
    case "udp":
      return await sendUdpRequest(uri, torrent);
    default:
      throw UnimplementedError("The Implementation for \"$protocol\" has not been done yet");
  }
}

Future<AnnounceResponse?> sendHttpRequest(Uri uri, TorrentContent torrent) async {
  final requestUri = buildHttpConnectionRequest(trackerUrl: uri.toString(), torrent: torrent);
  final res = await http.get(requestUri);
  final resBytes = res.bodyBytes;

  final parsedResponse = parseAnnounceStringResponse(resBytes);

  print(parsedResponse.toString());

  return parsedResponse;
}

Future<AnnounceResponse?> sendUdpRequest(Uri uri, TorrentContent content) async {
  final reqData = buildConnReq();

  const localPort = 0; // Use 58821 for testing ig

  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
  s.broadcastEnabled = true;

  // uri = Uri.parse(aurl);

  final iadr = await InternetAddress.lookup(uri.host);
  // print(iadr);
  // print(content.infoHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join(''));
  if (iadr.isEmpty) {
    print("Address lookup failed.");
  }

  final ip = iadr.firstWhere((i) => i.type == InternetAddressType.IPv4);

  Completer<Uint8List?> completer = Completer();
  s.listen((RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final res = s.receive();
      if (res != null) {
        print("Got a response from $ip");
        completer.complete(res.data);
        s.close();
      }
    }
  });

  s.send(reqData, ip, uri.port);

  Uint8List? response = await completer.future.timeout(
    Duration(seconds: 5),
    onTimeout: () {
      s.close();
      print("${ip.address}: Connection Timed Out.");
      return null;
    },
  );

  if (response != null) {
    final parsedConnRes = parseConnResponse(response);

    // Send announce req
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final annReq = buildAnnounceRequest(connId: parsedConnRes.connectionId, torrent: content); // Use default port

    Completer<Uint8List?> completer = Completer();
    bool responseReceived = false;

    sock.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          final res = sock.receive();
          if (res != null) {
            print("Got announce response! port: ${sock.port}");

            if (!responseReceived) {
              responseReceived = true;
              completer.complete(res.data);
              sock.close();
            } else {
              print("Ignoring additional response for port: ${sock.port}");
            }
          }
        }
      },
    );

    sock.send(annReq, ip, uri.port);

    final annRes = await completer.future.timeout(Duration(seconds: 5), onTimeout: () {
      print("Timeout for port: ${sock.port}");
      sock.close();
      return null;
    });

    if (annRes != null) {
      final parsedAnnRes = parseAnnounceBufferResponse(annRes);
      print("Announce success: ${sock.port}");
      return parsedAnnRes;
    } else {
      return null;
    }
  }
  return null;
}
