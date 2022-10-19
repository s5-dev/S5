import 'dart:io';
import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:cryptography/helpers.dart';
import 'package:s5_server/constants.dart';
import 'package:tint/tint.dart';
import 'package:toml/toml.dart';

import 'package:s5_server/node.dart';
import 'package:s5_server/logger/console.dart';

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

  if (file
      .readAsStringSync()
      .contains('"AUTOMATICALLY_GENERATED_ON_FIRST_START"')) {
    logger.info('Generating seed...');
    final seed = Uint8List(64);
    fillBytesWithSecureRandom(seed);

    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
            '"AUTOMATICALLY_GENERATED_ON_FIRST_START"',
            '"${base58Bitcoin.encode(seed)}"',
          ),
    );
  }

  final config = (await TomlDocument.load(file.path)).toMap();

  final node = S5Node(
    config,
    logger,
  );

  await node.start();
}
