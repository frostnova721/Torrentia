import 'dart:typed_data';

/// A set of piece indexes, stored in the BitTorrent wire format
/// (big-endian bits: piece 0 is the high bit of byte 0).
class Bitfield {
  final int length;
  final Uint8List bytes;
  int _count = 0;

  Bitfield(this.length) : bytes = Uint8List((length + 7) >> 3);

  Bitfield.full(this.length) : bytes = Uint8List((length + 7) >> 3) {
    for (var i = 0; i < length; i++) {
      set(i);
    }
  }

  /// Builds a bitfield from wire bytes. Spare bits past [length] are ignored.
  Bitfield.fromBytes(Uint8List source, this.length) : bytes = Uint8List((length + 7) >> 3) {
    final n = source.length < bytes.length ? source.length : bytes.length;
    bytes.setRange(0, n, source);
    if (length & 7 != 0 && bytes.isNotEmpty) {
      bytes[bytes.length - 1] &= (0xff << (8 - (length & 7))) & 0xff;
    }
    for (var i = 0; i < length; i++) {
      if (this[i]) _count++;
    }
  }

  bool operator [](int index) => (bytes[index >> 3] & (0x80 >> (index & 7))) != 0;

  void set(int index, [bool value = true]) {
    if (this[index] == value) return;
    if (value) {
      bytes[index >> 3] |= 0x80 >> (index & 7);
      _count++;
    } else {
      bytes[index >> 3] &= ~(0x80 >> (index & 7)) & 0xff;
      _count--;
    }
  }

  int get count => _count;
  bool get isComplete => _count == length;
  bool get isEmpty => _count == 0;

  Iterable<int> get setIndexes sync* {
    for (var i = 0; i < length; i++) {
      if (this[i]) yield i;
    }
  }
}
