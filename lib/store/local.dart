import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:path/path.dart';

import 'base.dart';

class LocalObjectStore extends ObjectStore {
  final Directory rootDir;

  final Map httpServerConfig;

  @override
  Future<void> init() async {}

  @override
  final uploadsSupported = true;

  LocalObjectStore(this.rootDir, this.httpServerConfig) {
    if (httpServerConfig['port'] != null) {
      final app = Alfred();
      final re = RegExp(r'^[a-z0-9A-Z]+$');

      app.all('*', cors());

      app.get('/*', (req, res) {
        for (final s in req.uri.pathSegments) {
          if (!re.hasMatch(s)) {
            if (s.endsWith('.obao') &&
                re.hasMatch(s.substring(0, s.length - 5))) {
            } else {
              throw 'Invalid path';
            }
          }
        }
        return File(joinAll([rootDir.path] + req.uri.pathSegments));
      });
      app.listen(
        httpServerConfig['port']!,
        httpServerConfig['bind'] ?? '0.0.0.0',
      );
    }
  }

  String getPathForHash(Multihash hash, [String? ext]) {
    final b =
        base32Rfc.encode(hash.fullBytes).toLowerCase().replaceAll('=', '');
    var path = '';

    for (int i = 0; i < 8; i += 2) {
      path += '${b.substring(i, i + 2)}/';
    }
    if (ext != null) {
      return '1/$path${b.substring(8)}.$ext';
    }

    return '1/$path${b.substring(8)}';
  }

  File getFileForPath(String path) {
    // TODO Windows support
    return File(join(rootDir.path, path));
  }

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async {
    for (final type in types) {
      if (type == storageLocationTypeArchive) {
        if (await contains(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFile) {
        if (await contains(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFull) {
        if ((await contains(hash)) &&
            getFileForPath(getPathForHash(hash, 'obao')).existsSync()) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  Future<StorageLocation> provide(Multihash hash, List<int> types) async {
    for (final type in types) {
      if (!(await canProvide(hash, [type]))) continue;
      if (type == storageLocationTypeArchive) {
        return StorageLocation(
          storageLocationTypeArchive,
          [],
          calculateExpiry(Duration(days: 1)),
        );
      } else if (type == storageLocationTypeFile ||
          type == storageLocationTypeFull) {
        return StorageLocation(
          type,
          [httpServerConfig['url'] + '/' + getPathForHash(hash)],
          calculateExpiry(Duration(hours: 1)),
        );
      }
    }
    throw 'Could not provide hash $hash for types $types';
  }

  // ! uploads

  @override
  Future<bool> contains(Multihash hash) async {
    return getFileForPath(getPathForHash(hash)).exists();
  }

  @override
  Future<void> put(
    Multihash hash,
    Stream<Uint8List> data,
    int length,
  ) async {
    if (await contains(hash)) {
      return;
    }

    final file = getFileForPath(getPathForHash(hash));
    file.parent.createSync(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    await sink.addStream(data);
    await sink.close();
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) {
    final file = getFileForPath(getPathForHash(hash, 'obao'));
    file.parent.createSync(recursive: true);
    return file.writeAsBytes(outboard);
  }

  @override
  Future<void> delete(Multihash hash) {
    final baoOutboardFile = getFileForPath(getPathForHash(hash, 'obao'));
    if (baoOutboardFile.existsSync()) {
      baoOutboardFile.deleteSync();
    }
    return getFileForPath(getPathForHash(hash)).delete();
  }

/*   @override
  Future<String> putAsyncUpload(Stream<Uint8List> data) async {
    final cacheFile = File(
      join(
        rootDir.path,
        'uploading-cache',
        generateUID(crypto),
      ),
    );

    await cacheFile.openWrite().addStream(data);

    return cacheFile.path;
  }

  @override
  Future<void> putAsyncFinalize(String key, Multihash hash) async {
    getFileForHash(hash).parent.createSync(recursive: true);
    await File(key).rename(getFileForHash(hash).path);
  } */
}
