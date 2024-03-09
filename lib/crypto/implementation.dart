import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';

import 'package:s5_server/rust/bridge_definitions.dart';

class RustCryptoImplementation extends CryptoImplementation {
  final Rust rust;

  RustCryptoImplementation(this.rust);

  final ed25519 = Ed25519();
  final _defaultSecureRandom = Random.secure();

  @override
  Uint8List generateRandomBytes(int length) {
    final bytes = Uint8List(length);

    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _defaultSecureRandom.nextInt(256);
    }

    return bytes;
  }

  @override
  Future<Uint8List> hashBlake3(Uint8List input) {
    return rust.hashBlake3(input: input);
  }

  @override
  Uint8List hashBlake3Sync(Uint8List input) {
    return rust.hashBlake3Sync(input: input);
  }

  @override
  Future<KeyPairEd25519> newKeyPairEd25519({required Uint8List seed}) async {
    final keyPair = await ed25519.newKeyPairFromSeed(seed);
    final pk = (await keyPair.extractPublicKey()).bytes;
    return KeyPairEd25519(Uint8List.fromList(seed + pk));
  }

  @override
  Future<Uint8List> signEd25519({
    required KeyPairEd25519 kp,
    required Uint8List message,
  }) async {
    final signature = await ed25519.sign(
      message,
      keyPair: SimpleKeyPairData(kp.extractBytes().sublist(0, 32),
          publicKey: SimplePublicKey(
            kp.extractBytes().sublist(32),
            type: KeyPairType.ed25519,
          ),
          type: KeyPairType.ed25519),
    );
    return Uint8List.fromList(signature.bytes);
  }

  @override
  Future<bool> verifyEd25519({
    required Uint8List pk,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    return ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          pk,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }

  @override
  Future<Uint8List> decryptXChaCha20Poly1305(
      {required Uint8List key,
      required Uint8List nonce,
      required Uint8List ciphertext}) {
    if (nonce.length != 24) {
      throw 'Invalid nonce length (decryption)';
    }
    return rust.decryptXchacha20Poly1305(
      key: key,
      nonce: nonce,
      ciphertext: ciphertext,
    );
  }

  @override
  Future<Uint8List> encryptXChaCha20Poly1305(
      {required Uint8List key,
      required Uint8List nonce,
      required Uint8List plaintext}) {
    if (nonce.length != 24) {
      throw 'Invalid nonce length (encryption)';
    }
    return rust.encryptXchacha20Poly1305(
      key: key,
      nonce: nonce,
      plaintext: plaintext,
    );
  }

  @override
  Future<Uint8List> hashBlake3File(
      {required int size, required OpenReadFunction openRead}) {
    // TODO: implement hashBlake3File
    throw UnimplementedError();
  }
}
