import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/util.dart';

class NodeID {
  final Uint8List bytes;
  NodeID(this.bytes);

  factory NodeID.decode(String nodeId) {
    return NodeID(base58Bitcoin.decode(nodeId.substring(1)));
  }

  @override
  bool operator ==(Object other) {
    if (other is! NodeID) {
      return false;
    }
    return areBytesEqual(bytes, other.bytes);
  }

  @override
  int get hashCode {
    return bytes[0] +
        (bytes[1] * 256) +
        (bytes[2] * 256 * 256) +
        (bytes[3] * 256 * 256 * 256);
  }

  String toBase58() {
    return 'z${base58Bitcoin.encode(bytes)}';
  }

  @override
  String toString() {
    return toBase58();
  }
}
