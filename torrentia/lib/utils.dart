import 'dart:math';
import 'dart:typed_data';

class TorrentiaUtils {
  /// The peer id
  static Uint8List? id;

  /// Generate peer id
  static Uint8List generateId() {
    if (id != null) {
      return id!;
    }
    final random = Random.secure();
    final byteList = Uint8List(20);
    for (int i = 0; i < 20; i++) {
      byteList[i] = random.nextInt(256);
    }
    final torrentiaPrefix = "-TT0001-".codeUnits;
    byteList.setRange(0, torrentiaPrefix.length, torrentiaPrefix);

    id = byteList;

    return id!;
  }
}
