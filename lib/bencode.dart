import 'dart:convert';
import 'dart:typed_data';

class BencodeException implements Exception {
  final String message;
  final int position;
  BencodeException(this.message, this.position);

  @override
  String toString() => 'BencodeException: $message (at byte $position)';
}

/// Result of decoding a bencoded document.
class BencodeResult {
  /// The decoded value. Byte strings are [Uint8List], integers are [int],
  /// lists are [List] and dictionaries are `Map<String, dynamic>`.
  final dynamic value;

  /// Raw byte spans `(start, end)` of each value in the top-level dictionary.
  /// Used to hash the `info` dict exactly as it appears in the file.
  final Map<String, (int, int)> topLevelSpans;

  BencodeResult(this.value, this.topLevelSpans);
}

/// Decodes [data]. Strings are left as raw bytes, because torrent files mix
/// text with binary data (e.g. `pieces`).
BencodeResult bdecode(Uint8List data) {
  final decoder = _Decoder(data);
  final value = decoder.next(0);
  if (decoder.pos != data.length) {
    throw BencodeException('Trailing data after root value', decoder.pos);
  }
  return BencodeResult(value, decoder.spans);
}

class _Decoder {
  final Uint8List data;
  int pos = 0;
  final Map<String, (int, int)> spans = {};

  _Decoder(this.data);

  int _peek() {
    if (pos >= data.length) throw BencodeException('Unexpected end of data', pos);
    return data[pos];
  }

  dynamic next(int depth) {
    if (depth > 64) throw BencodeException('Nesting too deep', pos);
    final c = _peek();
    switch (c) {
      case 0x64: // d
        pos++;
        final map = <String, dynamic>{};
        while (_peek() != 0x65) {
          final key = utf8.decode(_string(), allowMalformed: true);
          final start = pos;
          map[key] = next(depth + 1);
          if (depth == 0) spans[key] = (start, pos);
        }
        pos++;
        return map;
      case 0x6c: // l
        pos++;
        final list = <dynamic>[];
        while (_peek() != 0x65) {
          list.add(next(depth + 1));
        }
        pos++;
        return list;
      case 0x69: // i
        pos++;
        final end = _indexOf(0x65);
        final text = ascii.decode(data.sublist(pos, end), allowInvalid: true);
        final value = int.tryParse(text);
        if (value == null) throw BencodeException('Invalid integer "$text"', pos);
        pos = end + 1;
        return value;
      default:
        if (c >= 0x30 && c <= 0x39) return _string();
        throw BencodeException('Unexpected byte 0x${c.toRadixString(16)}', pos);
    }
  }

  Uint8List _string() {
    final colon = _indexOf(0x3a);
    final length = int.tryParse(ascii.decode(data.sublist(pos, colon), allowInvalid: true));
    if (length == null || length < 0) throw BencodeException('Invalid string length', pos);
    final start = colon + 1;
    final end = start + length;
    if (end > data.length) throw BencodeException('String runs past end of data', pos);
    pos = end;
    return Uint8List.sublistView(data, start, end);
  }

  int _indexOf(int byte) {
    for (var i = pos; i < data.length; i++) {
      if (data[i] == byte) return i;
    }
    throw BencodeException('Missing delimiter "${String.fromCharCode(byte)}"', pos);
  }
}

/// Encodes [value]: `String`, `Uint8List` (byte string), `int`, `List` or `Map`.
Uint8List bencode(dynamic value) {
  final out = BytesBuilder(copy: false);
  void write(dynamic v) {
    if (v is String) {
      final bytes = utf8.encode(v);
      out.add(ascii.encode('${bytes.length}:'));
      out.add(bytes);
    } else if (v is Uint8List) {
      out.add(ascii.encode('${v.length}:'));
      out.add(v);
    } else if (v is int) {
      out.add(ascii.encode('i${v}e'));
    } else if (v is List) {
      out.addByte(0x6c);
      v.forEach(write);
      out.addByte(0x65);
    } else if (v is Map) {
      out.addByte(0x64);
      final keys = v.keys.cast<String>().toList()..sort();
      for (final k in keys) {
        write(k);
        write(v[k]);
      }
      out.addByte(0x65);
    } else {
      throw ArgumentError('Cannot bencode ${v.runtimeType}');
    }
  }

  write(value);
  return out.toBytes();
}
