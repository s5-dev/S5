import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/registry.dart';
import 'package:lib5/util.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart';
import 'package:s5_server/db/hive_key_value_db.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/store/base.dart';

class FileSystemProviderObjectStore extends ObjectStore {
  final List<Directory> localDirectories;

  final metadataHashes = <Multihash, Uint8List>{};
  final fileHashes = <Multihash, String>{};

  final S5Node node;

  @override
  Future<void> init() async {
    final cacheBox = HiveKeyValueDB(
      await Hive.openBox<Uint8List>(
        'fs_provider_cache',
      ),
    );

    final fsSecret = deriveHashBlake3(
      node.p2p.nodeKeyPair.extractBytes().sublist(0, 32),
      utf8.encode('fs_provider'),
      crypto: node.crypto,
    );

    for (final dir in localDirectories) {
      final dirs = <String, DirectoryMetadata>{};
      // final dirHashes = <String, Multihash>{};

      void makeSureDirExists(String path) {
        if (!dirs.containsKey(path)) {
          dirs[path] = DirectoryMetadata(
            details: DirectoryMetadataDetails({}),
            directories: {},
            files: {},
            extraMetadata: ExtraMetadata({}),
          );
        }
      }

      makeSureDirExists('');

      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final size = entity.lengthSync();

          final stat = entity.statSync();

          final key = node.crypto.hashBlake3Sync(
            Uint8List.fromList(
              utf8.encode(
                '$size-${stat.modified.millisecondsSinceEpoch}-${entity.path}',
              ),
            ),
          );
          if (!cacheBox.contains(key)) {
            print('b3hash ${entity.path}');
            final hash = await node.rust.hashBlake3File(path: entity.path);
            cacheBox.set(key, hash);
          }
          final dirPath = dirname(entity.path).substring(dir.path.length);

          makeSureDirExists(dirPath);

          final filename = basename(entity.path);

          final hash = Multihash(Uint8List.fromList(
            [mhashBlake3Default] + cacheBox.get(key)!,
          ));

          fileHashes[hash] = entity.path;

          dirs[dirPath]!.files[filename] = FileReference(
            name: filename,
            created: stat.modified.millisecondsSinceEpoch,
            version: 0,
            mimeType: lookupMimeType(filename),
            file: FileVersion(
              ts: stat.modified.millisecondsSinceEpoch,
              plaintextCID: CID(
                cidTypeRaw,
                hash,
                size: size,
              ),
            ),
          );
        } else if (entity is Directory) {
          makeSureDirExists(entity.path.substring(dir.path.length));
        }
      }
      final dirPaths = dirs.keys.toList();
      dirPaths.sort((a, b) => -a.length.compareTo(b.length));

      for (final path in dirPaths) {
        final keyPair = await node.crypto.newKeyPairEd25519(
          seed: deriveHashBlake3(
            fsSecret,
            utf8.encode(dir.path + path),
            crypto: node.crypto,
          ),
        );

        final slashIndex = path.lastIndexOf('/');
        if (slashIndex != -1) {
          final parentPath = path.substring(0, slashIndex);
          final dirname = path.substring(slashIndex + 1);

          dirs[parentPath]!.directories[dirname] = DirectoryReference(
            created: Directory(dir.path + path)
                .statSync()
                .modified
                .millisecondsSinceEpoch,
            name: dirname,
            encryptedWriteKey: Uint8List(0),
            publicKey: keyPair.publicKey,
            encryptionKey: null,
          );
        }
        final dirBytes = dirs[path]!.serialize();
        final hash = Multihash(
          Uint8List.fromList(
            [mhashBlake3Default] + node.crypto.hashBlake3Sync(dirBytes),
          ),
        );

        metadataHashes[hash] = dirBytes;

        // CID type directory
        final cid = CID(
          0x5d,
          hash,
          size: dirBytes.length,
        );
        final res = node.registry.getFromDB(keyPair.publicKey);

        if (res == null || !areBytesEqual(res.data, cid.toRegistryEntry())) {
          final sre = await signRegistryEntry(
            kp: keyPair,
            data: cid.toRegistryEntry(),
            revision: (res?.revision ?? -1) + 1,
            crypto: node.crypto,
          );
          await node.registry.set(
            sre,
            trusted: true,
          );
        }

        if (path.isEmpty) {
          node.logger.info(
            '${dir.path}: skyfs://${base64UrlNoPaddingEncode(keyPair.publicKey)}@shared-readonly CID: $cid',
          );
        }
      }
    }
  }

  @override
  final uploadsSupported = false;

  final String externalDownloadUrl;

  final int httpPort;
  final String httpBind;

  FileSystemProviderObjectStore(
    this.node, {
    required this.localDirectories,
    required this.httpPort,
    required this.httpBind,
    required this.externalDownloadUrl,
  }) {
    final app = Alfred();

    app.all('*', cors());

    app.get('/hash/:hash', (req, res) {
      final hash = Multihash.fromBase64Url(req.params['hash']);
      if (metadataHashes.containsKey(hash)) {
        res.add(metadataHashes[hash]!);
        res.close();
      } else if (fileHashes.containsKey(hash)) {
        return File(fileHashes[hash]!);
      }
    });
    app.listen(
      httpPort,
      httpBind,
    );
  }

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async {
    for (final type in types) {
      if (type == storageLocationTypeFile) {
        if (await contains(hash)) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  Future<StorageLocation> provide(Multihash hash, List<int> types) async {
    return StorageLocation(
      3,
      // TODO Increase expiry
      ['$externalDownloadUrl/hash/${hash.toBase64Url()}'],
      calculateExpiry(Duration(minutes: 10)),
    );
  }

  // ! uploads

  @override
  Future<bool> contains(Multihash hash) async {
    return metadataHashes.containsKey(hash) || fileHashes.containsKey(hash);
  }

  @override
  Future<void> put(
    Multihash hash,
    Stream<Uint8List> data,
    int length,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) {
    throw UnimplementedError();
  }

  @override
  Future<void> delete(Multihash hash) {
    throw UnimplementedError();
  }
}
