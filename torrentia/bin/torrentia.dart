import 'package:torrentia/tracker.dart';

Future<void> main(List<String> arguments) async {
  await Tracker().getPeers();

}
