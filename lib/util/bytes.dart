import 'dart:typed_data';

import 'package:s5_server/constants.dart';
import 'package:s5_server/crypto/blake3.dart';
import 'package:s5_server/model/multihash.dart';

bool ensureIntegrity(Multihash hash, Uint8List bytes) {
  final h = BLAKE3.hash(bytes);
  return equal(hash.bytes, Uint8List.fromList(mhashBlake3 + h));
}

bool equal(Uint8List l1, Uint8List l2) {
  if (l1.length != l2.length) return false;

  for (int i = 0; i < l1.length; i++) {
    if (l1[i] != l2[i]) return false;
  }
  return true;
}
