

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
      throw UnimplementedError("The Implementation for \"$protocol\" has not been done yet");
  }
}



// final client = http.Client();

Future<dynamic> sendHttpRequest(Uri uri, TorrentContent torrent) async {
  final requestUri = buildHttpConnectionRequest(trackerUrl: uri.toString(), torrent: torrent);
  final res = await http.get(requestUri);
  final resBytes = res.bodyBytes;

  final parsedResponse = parseAnnounceStringResponse(resBytes);

  print(parsedResponse.toString());

  return parsedResponse;
}

Future<dynamic> sendUdpRequest(Uri uri, TorrentContent content) async {
  // final reqData = buildConnReq();
  // final s = RawDatagramSocket.bind(, 6881);
  // final sender = await UDP.bind();
  // final res = sender.send(reqData, Endpoint.any(port: 65001));
  // final announceReq = buildAnnounceRequest(torrent: content, connId: rdbv.get);

}
