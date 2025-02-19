import 'dart:async';
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

  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  s.broadcastEnabled = true;

  final Map<int, Uri> transactionMap = {};

  s.listen((RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final res = s.receive();
      print(res);
      if (res != null) {
        final parsedResponse = parseConnResponse(res.data);
        print("Received response: $parsedResponse");

        // Optional: Match response with sent transaction
        final transactionId =
            parsedResponse.transactionId; // Extract from response
        if (transactionMap.containsKey(transactionId)) {
          print("Matched response from ${transactionMap[transactionId]}");
          transactionMap.remove(transactionId);
        }
      }
    }
  });

  for (final url in content.announceList) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != "udp") continue;
      print(url);
      final iadr = await InternetAddress.lookup(uri.host);
      if (iadr.isEmpty) {
        print("Address lookup failed.");
        continue;
      }

      final transactionId =
          extractTransactionId(reqData); // Extract from request data
      transactionMap[transactionId] = uri;

      final sender = s.send(reqData, iadr.first, uri.port);
      print(sender);

      await Future.delayed(Duration(milliseconds: 500));
      // if (event == RawSocketEvent.read) {
      // final res = s.receive();
      // if (res != null) {
      //   final parsedResponse = parseConnResponse(res.data);
      //   print("Received response: $parsedResponse");
      // }
      // }
    } catch (err) {
      print("Failed to establish connection with $url");
      print(err);
    }
    await Future.delayed(Duration(seconds: 5));
    // s.close();
  }
  // final res = sender.send(reqData, Endpoint.any(port: 65001));
  // final announceReq = buildAnnounceRequest(torrent: content, connId: rdbv.get);
}

int extractTransactionId(Uint8List data) {
  final byteView = ByteData.sublistView(data);
  return byteView.getUint32(12, Endian.big); // Extracts the last 4 bytes
}
