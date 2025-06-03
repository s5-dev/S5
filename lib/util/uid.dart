import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/lib5.dart';

String generateUID(CryptoImplementation crypto) {
  final uid = crypto.generateSecureRandomBytes(32);
  return base32Rfc.encode(uid).replaceAll('=', '').toLowerCase();
}
