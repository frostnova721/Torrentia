import 'package:torrentia/download.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/network/requesters.dart';

class Tracker {
  Future<dynamic> getPeers() async {
    final content = await Reader().readFromFile("assets/big-buck-bunny.torrent");
    print(content);
    final res = await sendAnnounceRequest(content);
    print(res.peers[0].ip);
    download(res.peers[0], content, []);
  }

  
}