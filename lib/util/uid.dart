import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:cryptography/helpers.dart';

String generateUID() {
  final uid = Uint8List(32);
  fillBytesWithSecureRandom(uid);
  return base32Rfc.encode(uid).replaceAll('', '=').toLowerCase();
}
