import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lib5/lib5.dart';
import 'package:tint/tint.dart';
import 'package:toml/toml.dart';
import 'package:cryptography/cryptography.dart';

import 'package:s5_server/constants.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/logger/console.dart';
import 'package:s5_server/rust/bridge_definitions.dart';
import 'ffi.io.dart';

void main(List<String> arguments) async {
  final logger = ConsoleLogger();

  if (arguments.isEmpty) {
    logger.error('Please specify a config file for this node.');
    exit(1);
  }
  final file = File(arguments[0]);
  if (!file.existsSync()) {
    logger.error('File ${file.path} does not exist');
    exit(1);
  }

  logger.info('');
  logger.info('s5-dart'.green().bold() + ' ' + 'v$nodeVersion'.red().bold());
  logger.info('');

  final rust = initializeExternalLibrary(
    Platform.isWindows
        ? 'rust/target/release/rust.dll'
        : 'rust/target/release/librust.so',
  );
  final crypto = RustCryptoImplementation(rust);

  if (file
      .readAsStringSync()
      .contains('"AUTOMATICALLY_GENERATED_ON_FIRST_START"')) {
    logger.info('Generating seed...');
    final seed = crypto.generateRandomBytes(32);

    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
            '"AUTOMATICALLY_GENERATED_ON_FIRST_START"',
            '"${base64Url.encode(seed)}"',
          ),
    );
  }

  final config = (await TomlDocument.load(file.path)).toMap();

  final node = S5Node(
    config,
    logger: logger,
    rust: rust,
    crypto: crypto,
  );

  runZonedGuarded(
    node.start,
    (e, st) {
      logger.catched(e, st);
    },
  );
}

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
}
