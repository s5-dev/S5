import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:s5_server/crypto/implementation.dart';
import 'package:tint/tint.dart';
import 'package:toml/toml.dart';

import 'package:s5_server/constants.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/logger/console.dart';

import 'ffi.io.dart';

void main(List<String> arguments) async {
  final logger = ConsoleLogger(
    format: true,
  );

  final isDocker = Platform.environment['DOCKER'] == 'TRUE';

  if (isDocker) {
    arguments = ['/config/config.toml'];
  } else if (arguments.isEmpty) {
    logger.error('Please specify a config file for this node.');
    exit(1);
  }

  final rust = initializeExternalLibrary(
    isDocker
        ? '/app/librust.so'
        : (Platform.isWindows
            ? './rust.dll'
            : './librust.so'),
  );
  final crypto = RustCryptoImplementation(rust);

  final file = File(arguments[0]);
  if (!file.existsSync()) {
    final seed = crypto.generateRandomBytes(32);
    file.createSync(recursive: true);
    file.writeAsStringSync(
      (isDocker ? defaultConfigDocker : defaultConfig).replaceFirst(
        '"AUTOMATICALLY_GENERATED_ON_FIRST_START"',
        '"${base64Url.encode(seed)}"',
      ),
    );
  }

  logger.info('');
  logger.info('s5-dart'.green().bold() + ' ' + 'v$nodeVersion'.red().bold());
  logger.info('');

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

const defaultConfig = '''# ! Documentation: https://docs.s5.ninja/install/config

name = "my-s5-node"

[keypair]
seed = "AUTOMATICALLY_GENERATED_ON_FIRST_START"

[cache] # Caches file objects that are uploaded, streamed or downloaded
path = "/tmp/s5/cache"

[database] # Caches peer and object data (small)
path = "data/hive"

[http.api]
port = 5050

[http.api.delete]
enabled = false

[p2p.peers]
initial = [
  'tcp://z2DWuWNZcdSyZLpXFK2uCU3haaWMXrDAgxzv17sDEMHstZb@199.247.20.119:4444', # s5.garden
  'tcp://z2DWuPbL5pweybXnEB618pMnV58ECj2VPDNfVGm3tFqBvjF@116.203.139.40:4444', # s5.ninja
]
''';

const defaultConfigDocker =
    '''# ! Documentation: https://docs.s5.ninja/install/config

name = "my-s5-node"

[keypair]
seed = "AUTOMATICALLY_GENERATED_ON_FIRST_START"

[cache] # Caches file objects that are uploaded, streamed or downloaded
path = "/cache"

[database] # Caches peer and object data (small)
path = "/db"

[http.api]
port = 5050
bind = '0.0.0.0'

[http.api.delete]
enabled = false

[p2p.peers]
initial = [
  'tcp://z2DWuWNZcdSyZLpXFK2uCU3haaWMXrDAgxzv17sDEMHstZb@199.247.20.119:4444', # s5.garden
  'tcp://z2DWuPbL5pweybXnEB618pMnV58ECj2VPDNfVGm3tFqBvjF@116.203.139.40:4444', # s5.ninja
]
''';
