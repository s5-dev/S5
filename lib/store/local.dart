import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/lib5.dart';
import 'package:path/path.dart';

import 'base.dart';

class LocalObjectStore extends ObjectStore {
  final Directory rootDir;

  final Map httpServerConfig;

  @override
  final canPutAsync = false;

  LocalObjectStore(this.rootDir, this.httpServerConfig) {
    final app = Alfred();
    final re = RegExp(r'^[a-z0-9A-Z]+$');
    app.get('/*', (req, res) {
      for (final s in req.uri.pathSegments) {
        if (!re.hasMatch(s)) {
          throw 'Invalid path';
        }
      }
      return File(joinAll([rootDir.path] + req.uri.pathSegments));
    });
    app.listen(
      httpServerConfig['port']!,
      httpServerConfig['bind'] ?? '0.0.0.0',
    );
  }

  String getPathForHash(Multihash hash) {
    final b =
        base32Rfc.encode(hash.fullBytes).toLowerCase().replaceAll('=', '');
    var path = '';

    for (int i = 0; i < 8; i += 2) {
      path += '${b.substring(i, i + 2)}/';
    }

    return '0/$path${b.substring(8)}';
  }

  File getFileForHash(Multihash hash) {
    return File(join(rootDir.path, getPathForHash(hash)));
  }

  @override
  Future<bool> contains(Multihash hash) async {
    return getFileForHash(hash).exists();
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

    getFileForHash(hash).parent.createSync(recursive: true);
    await getFileForHash(hash)
        .openWrite(mode: FileMode.writeOnly)
        .addStream(data);
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

  @override
  Future<String> provide(Multihash hash) async {
    return httpServerConfig['url'] + '/' + getPathForHash(hash);
  }

  @override
  Future<void> delete(Multihash hash) {
    return getFileForHash(hash).delete();
  }
}
