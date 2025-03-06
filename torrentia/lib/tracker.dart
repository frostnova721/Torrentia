import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/network/requesters.dart';

class Tracker {
  Future<dynamic> getPeers() async {
    final content = await Reader().readFromFile("assets/bbt.torrent");
    print(content);
    List<Future<AnnounceResponse?>> annResps = [];

    for (final annUrl in content.announceList) {
      final res = sendAnnounceRequest(annUrl, content).catchError((e) {
        print("Error contacting tracker $annUrl: $e");
        return null;
      });
      annResps.add(res);
    }

    List<AnnounceResponse?> results = await Future.wait(annResps);
    final nonNullRes = results.where((it) => it != null);
    print("Got ${nonNullRes.length} results");
  }
}
