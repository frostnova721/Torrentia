import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class TorrentiaUtils {
  static Uint8List? _id;

  /// A process-wide default 20-byte peer id. Sessions create their own with [newPeerId].
  static Uint8List generateId() => _id ??= newPeerId();

  /// A fresh Azureus-style peer id: `-TT0001-` + 12 random bytes.
  static Uint8List newPeerId() {
    final random = Random.secure();
    final id = Uint8List(20);
    for (var i = 0; i < 20; i++) {
      id[i] = random.nextInt(256);
    }
    id.setRange(0, 8, '-TT0001-'.codeUnits);
    return id;
  }

  static String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String formatBytes(num bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

/// Which network addresses untrusted inputs (trackers, peer lists, torrent
/// web seeds) may make us contact.
class NetworkPolicy {
  /// When false (default), addresses from trackers/torrents that point into
  /// loopback, private LAN, link-local, CGNAT or multicast ranges are refused,
  /// so a malicious tracker or torrent can't probe the local network.
  static bool allowPrivateNetworks = false;

  static bool isAllowed(InternetAddress a) => allowPrivateNetworks || isPublicAddress(a);

  /// Resolves [host] and throws if any address is not allowed.
  static Future<void> checkHost(String host) async {
    if (allowPrivateNetworks) return;
    final parsed = InternetAddress.tryParse(host);
    final addresses = parsed != null ? [parsed] : await InternetAddress.lookup(host);
    if (addresses.isEmpty || !addresses.every(isPublicAddress)) {
      throw SocketException('Refusing to contact non-public host $host');
    }
  }
}

/// True for globally routable unicast addresses.
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    final x = b[0], y = b[1];
    if (x == 0 || x == 10 || x == 127) return false; // this-network, private, loopback
    if (x == 100 && y >= 64 && y <= 127) return false; // CGNAT 100.64/10
    if (x == 169 && y == 254) return false; // link-local
    if (x == 172 && y >= 16 && y <= 31) return false; // private
    if (x == 192 && y == 168) return false; // private
    if (x == 192 && y == 0 && b[2] == 0) return false; // IETF protocol assignments
    if (x >= 224) return false; // multicast, reserved, broadcast
    return true;
  }
  if (a.type == InternetAddressType.IPv6) {
    if (b.every((v) => v == 0)) return false; // ::
    if (b.sublist(0, 15).every((v) => v == 0) && b[15] == 1) return false; // ::1
    if (b[0] == 0xff) return false; // multicast
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // link-local fe80::/10
    if ((b[0] & 0xfe) == 0xfc) return false; // unique local fc00::/7
    // IPv4-mapped ::ffff:a.b.c.d
    if (b.sublist(0, 10).every((v) => v == 0) && b[10] == 0xff && b[11] == 0xff) {
      return isPublicAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
    }
    return true;
  }
  return false;
}

/// Reads at most [limit] bytes from [stream]; throws if it's longer.
Future<Uint8List> readLimited(Stream<List<int>> stream, int limit) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    out.add(chunk);
    if (out.length > limit) throw const FormatException('Response too large');
  }
  return out.toBytes();
}

enum LogLevel { debug, info, warn, error }

/// Minimal logger. Set [Log.level] to control verbosity, or replace [Log.sink].
class Log {
  static LogLevel level = LogLevel.info;
  static void Function(String line) sink = print;

  static void debug(String msg) => _log(LogLevel.debug, msg);
  static void info(String msg) => _log(LogLevel.info, msg);
  static void warn(String msg) => _log(LogLevel.warn, msg);
  static void error(String msg) => _log(LogLevel.error, msg);

  static void _log(LogLevel l, String msg) {
    if (l.index < level.index) return;
    sink('[${l.name.toUpperCase()}] $msg');
  }
}
