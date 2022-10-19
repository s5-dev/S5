import 'dart:convert';
import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';

class Multihash {
  final Uint8List bytes;

  // TODO Make it possible to compare this object and use it as a key directly
  String get key => String.fromCharCodes(bytes);

  Multihash(this.bytes);
  @override
  String toString() {
    return toBase58();
  }

  String toBase58() {
    return base58Bitcoin.encode(bytes);
  }

  String toBase64Url() {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String toBase32() {
    // ignore: prefer_interpolation_to_compose_strings
    return base32Rfc.encode(bytes).replaceAll('=', '').toLowerCase();
  }
}
