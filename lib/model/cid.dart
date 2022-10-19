import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:s5_server/constants.dart';

import 'multihash.dart';

class CID {
  late final int type;

  late final Multihash hash;
  CID(this.type, this.hash);

  CID.decode(String cid) {
    final Uint8List bytes;
    if (cid.startsWith('z')) {
      bytes = base58BitcoinDecode(cid.substring(1));
    } else if (cid.startsWith('b')) {
      var str = cid.substring(1).toUpperCase();
      while (str.length % 4 != 0) {
        str = '$str=';
      }
      bytes = base32Rfc.decode(str);
    } else {
      throw 'Encoding not supported';
    }

    type = bytes[0];
    hash = Multihash(bytes.sublist(1));
  }

  CID.fromBytes(Uint8List bytes) {
    type = bytes[0];
    hash = Multihash(bytes.sublist(1));
  }

  String encode() {
    // ignore: prefer_interpolation_to_compose_strings
    return 'z' + base58Bitcoin.encode(toBinary());
  }

  Uint8List toBinary() {
    return Uint8List.fromList([type] + hash.bytes);
  }

  Uint8List toRegistryEntry() {
    return Uint8List.fromList([registryS5MagicByte, type] + hash.bytes);
  }

  @override
  String toString() {
    return encode();
  }

  String toBase32() {
    // ignore: prefer_interpolation_to_compose_strings
    return 'b' + base32Rfc.encode(toBinary()).replaceAll('=', '').toLowerCase();
  }
}
