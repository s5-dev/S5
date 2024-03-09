import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';

import 'base.dart';

class PixeldrainObjectStore extends ObjectStore {
  final String apiKey;

  PixeldrainObjectStore(this.apiKey) {
    _headers = {
      'Authorization': 'Basic ${base64Url.encode(utf8.encode(':$apiKey'))}'
    };
  }

  late final Map<String, String> _headers;

  final httpClient = Client();
  final ioHttpClient = HttpClient();

  final availableHashes = <Multihash, String>{};
  final availableBaoOutboardHashes = <Multihash, String>{};

  @override
  Future<Iterable<Multihash>> getStoredHashes() async {
    return availableHashes.keys;
  }

  Uri _getApiUri(String path) {
    return Uri.parse('https://pixeldrain.com/api$path');
  }

  @override
  Future<void> init() async {
    final res = await httpClient.get(
      _getApiUri('/user/files'),
      headers: _headers,
    );
    final files = jsonDecode(res.body)['files'];
    for (final file in files) {
      try {
        final String name = file['name'];
        final String id = file['id'];
        if (name.endsWith('.obao')) {
          availableBaoOutboardHashes[
              Multihash.fromBase64Url(name.split('.')[0])] = id;
        } else {
          availableHashes[Multihash.fromBase64Url(name)] = id;
        }
      } catch (e, st) {
        // TODO Proper logging
        print(e);
      }
    }
  }

  @override
  final uploadsSupported = true;

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '${hash.toBase64Url()}.$ext';
    }
    return hash.toBase64Url();
  }

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async {
    for (final type in types) {
      if (type == storageLocationTypeArchive) {
        if (availableHashes.containsKey(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFile) {
        if (availableHashes.containsKey(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFull) {
        if (availableHashes.containsKey(hash) &&
            availableBaoOutboardHashes.containsKey(hash)) {
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
        final fileUrl =
            'https://pixeldrain.com/api/file/${availableHashes[hash]!}';

        if (type == storageLocationTypeFile) {
          return StorageLocation(
            storageLocationTypeFile,
            [fileUrl],
            calculateExpiry(Duration(hours: 1)),
          );
        }

        final outboardUrl =
            'https://pixeldrain.com/api/file/${availableBaoOutboardHashes[hash]!}';

        return StorageLocation(
          storageLocationTypeFull,
          [
            fileUrl,
            outboardUrl,
          ],
          calculateExpiry(Duration(hours: 1)),
        );
      }
    }
    throw 'Could not provide hash $hash for types $types';
  }

  // ! writes

  @override
  Future<bool> contains(Multihash hash) async {
    return availableHashes.containsKey(hash);
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

    final req = await ioHttpClient.openUrl(
      'PUT',
      _getApiUri('/file/${getObjectKeyForHash(hash)}'),
    );
    for (final h in _headers.entries) {
      req.headers.set(h.key, h.value);
    }

    await req.addStream(data).timeout(const Duration(minutes: 10));

    final res = await req.close();

    if (res.statusCode != 201) {
      throw Exception('HTTP ${res.statusCode}');
    }

    final resBody = await utf8.decoder.bind(res).join();

    availableHashes[hash] = json.decode(resBody)['id'];
  }

  @override
  Future<void> delete(Multihash hash) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      final res = await httpClient.delete(
        _getApiUri('/file/${availableBaoOutboardHashes[hash]!}'),
        headers: _headers,
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }

      availableBaoOutboardHashes.remove(hash);
    }
    if (availableHashes.containsKey(hash)) {
      final res = await httpClient.delete(
        _getApiUri('/file/${availableHashes[hash]!}'),
        headers: _headers,
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }

      availableHashes.remove(hash);
    }
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }
    final res = await httpClient.put(
      _getApiUri('/file/${getObjectKeyForHash(hash, 'obao')}'),
      body: outboard,
      headers: _headers,
    );

    if (res.statusCode != 201) {
      throw 'Upload failed: HTTP ${res.statusCode}: ${res.body}';
    }
    availableBaoOutboardHashes[hash] = json.decode(res.body)['id'];
  }

  @override
  Future<AccountInfo> getAccountInfo() async {
    final res = await httpClient.get(
      _getApiUri('/user'),
      headers: _headers,
    );

    final userInfo = jsonDecode(res.body);
    final int expiryDays = userInfo['subscription']['file_expiry_days'];
    final int storageSpace = userInfo['subscription']['storage_space'];

    return AccountInfo(
      serviceName: 'Pixeldrain',
      userIdentifier: userInfo['username'],
      usedStorageBytes: userInfo['storage_space_used'],
      totalStorageBytes: storageSpace == -1 ? null : storageSpace,
      expiryDays: expiryDays == -1 ? null : expiryDays,
      maxFileSize: userInfo['subscription']['file_size_limit'],
      warning: userInfo['hotlinking_enabled'] != true
          ? 'Hotlinking needs to be enabled for downloads to work'
          : null,
      subscription: userInfo['subscription']['name'],
    );
  }
}
