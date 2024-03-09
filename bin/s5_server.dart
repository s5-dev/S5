import 'dart:async';
import 'dart:io';

import 'package:lib5/util.dart';
import 'package:s5_server/crypto/implementation.dart';
import 'package:tint/tint.dart';
import 'package:toml/toml.dart';

import 'package:s5_server/constants.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/logger/console.dart';

import 'ffi.io.dart';

void main(List<String> arguments) async {
  final isDocker = Platform.environment['DOCKER'] == 'TRUE';

  final logger = ConsoleLogger(
    format: !isDocker,
  );

  if (isDocker) {
    arguments = ['/config/config.toml'];
  } else if (arguments.isEmpty) {
    logger.error('Please specify a config file for this node.');
    exit(1);
  }

  final rust = initializeExternalLibrary(
    isDocker
        ? '/app/librust.so'
        : (Platform.isWindows ? './rust.dll' : './librust.so'),
  );
  final crypto = RustCryptoImplementation(rust);

  final file = File(arguments[0]);
  if (!file.existsSync()) {
    final seed = crypto.generateRandomBytes(32);
    file.createSync(recursive: true);
    file.writeAsStringSync(
      (isDocker ? defaultConfigDocker : defaultConfig).replaceFirst(
        '"AUTOMATICALLY_GENERATED_ON_FIRST_START"',
        '"${base64UrlNoPaddingEncode(seed)}"',
      ),
    );
  }

  final config = (await TomlDocument.load(file.path)).toMap();
  if (config['logger']?['file'] != null) {
    logger.sink = File(config['logger']['file']!)
        .openWrite(mode: FileMode.writeOnlyAppend);
  }

  logger.info('');
  logger.info('s5-dart'.green().bold() + ' ' + 'v$nodeVersion'.red().bold());
  logger.info('');

  final node = S5Node(
    config: config,
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

const defaultConfig =
    '''# ! Documentation: https://docs.sfive.net/install/config

name = "my-s5-node"

[keypair]
seed = "AUTOMATICALLY_GENERATED_ON_FIRST_START"

[cache] # Caches file objects that are uploaded, streamed or downloaded
path = "/tmp/s5/cache"
maxSizeInGB = 4

[database] # Caches peer and object data (small)
path = "data/hive"

[http.api]
port = 5050

[p2p.peers]
initial = [
  'wss://z2Das8aEF7oNoxkcrfvzerZ1iBPWfm6D7gy3hVE4ALGSpVB@node.sfive.net/s5/p2p',
  'wss://z2DdbxV4xyoqWck5pXXJdVzRnwQC6Gbv6o7xDvyZvzKUfuj@s5.vup.dev/s5/p2p',
  'wss://z2DWuWNZcdSyZLpXFK2uCU3haaWMXrDAgxzv17sDEMHstZb@s5.garden/s5/p2p',
]
''';

const defaultConfigDocker =
    '''# ! Documentation: https://docs.sfive.net/install/config

name = "my-s5-node"

[keypair]
seed = "AUTOMATICALLY_GENERATED_ON_FIRST_START"

[cache] # Caches file objects that are uploaded, streamed or downloaded
path = "/cache"
maxSizeInGB = 4

[database] # Caches peer and object data (small)
path = "/db"

[http.api]
port = 5050
bind = '0.0.0.0'

[p2p.peers]
initial = [
  'wss://z2Das8aEF7oNoxkcrfvzerZ1iBPWfm6D7gy3hVE4ALGSpVB@node.sfive.net/s5/p2p',
  'wss://z2DdbxV4xyoqWck5pXXJdVzRnwQC6Gbv6o7xDvyZvzKUfuj@s5.vup.dev/s5/p2p',
  'wss://z2DWuWNZcdSyZLpXFK2uCU3haaWMXrDAgxzv17sDEMHstZb@s5.garden/s5/p2p',
]
''';
