import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';

import 'base.dart';

class SiaObjectStore extends ObjectStore {
  final String busApiUrl;
  final String workerApiUrl;
  final String apiPassword;
  final Client httpClient;

  final List<String> downloadUrls;

  late final Map<String, String> _headers;

  final availableHashes = <Multihash>{};
  final availableBaoOutboardHashes = <Multihash>{};

  Uri _getApiUri(String path) {
    return Uri.parse('$workerApiUrl$path');
  }

  @override
  Future<void> init() async {
    final res =
        await httpClient.get(_getApiUri('/objects/1/'), headers: _headers);
    if (res.statusCode == 500) {
      return;
    }
    if (res.statusCode != 200) {
      throw 'HTTP ${res.statusCode}: ${res.body}';
    }
    final objects = json.decode(res.body);

    for (final object in objects) {
      final String key = object['name'];
      if (key.endsWith('.obao')) {
        availableBaoOutboardHashes.add(
          Multihash.fromBase64Url(key.substring(3).split('.')[0]),
        );
      } else {
        availableHashes.add(
          Multihash.fromBase64Url(key.substring(3)),
        );
      }
    }
  }

  @override
  final uploadsSupported = true;

  SiaObjectStore({
    required this.workerApiUrl,
    required this.busApiUrl,
    required this.apiPassword,
    required this.httpClient,
    required this.downloadUrls,
  }) {
    _headers = {
      'Authorization': 'Basic ${base64Url.encode(utf8.encode(':$apiPassword'))}'
    };
  }

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '/objects/1/${hash.toBase64Url()}.$ext';
    }
    return '/objects/1/${hash.toBase64Url()}';
  }

  final _random = Random();

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async {
    for (final type in types) {
      if (type == storageLocationTypeArchive) {
        if (availableHashes.contains(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFile) {
        if (availableHashes.contains(hash)) {
          return true;
        }
      } else if (type == storageLocationTypeFull) {
        if (availableHashes.contains(hash) &&
            availableBaoOutboardHashes.contains(hash)) {
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
        if (downloadUrls.isNotEmpty) {
          final String downloadUrl;
          if (downloadUrls.length == 1) {
            downloadUrl = downloadUrls.first;
          } else {
            downloadUrl = downloadUrls[_random.nextInt(downloadUrls.length)];
          }

          return StorageLocation(
            type,
            ['$downloadUrl/${hash.toBase64Url()}'],
            calculateExpiry(Duration(hours: 1)),
          );
        }
      }
    }
    throw 'Could not provide hash $hash for types $types';
  }

  // ! writes

  @override
  Future<bool> contains(Multihash hash) async {
    return availableHashes.contains(hash);
  }

  final ioHttpClient = HttpClient();

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
      _getApiUri(getObjectKeyForHash(hash)),
    );
    for (final h in _headers.entries) {
      req.headers.set(h.key, h.value);
    }

    await req.addStream(data);

    final res = await req.close();

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }

    final resBody = await utf8.decoder.bind(res).join();

    availableHashes.add(hash);
  }

  @override
  Future<void> delete(Multihash hash) async {
    throw UnimplementedError();
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.contains(hash)) {
      return;
    }
    final res = await httpClient.put(
      _getApiUri(
        getObjectKeyForHash(hash, 'obao'),
      ),
      body: outboard,
      headers: _headers,
    );

    if (res.statusCode != 200) {
      throw 'Upload failed: HTTP ${res.statusCode}: ${res.body}';
    }
    availableBaoOutboardHashes.add(hash);
  }

  @override
  Future<AccountInfo> getAccountInfo() async {
    final res = await httpClient.get(
      Uri.parse('$busApiUrl/stats/objects'),
      headers: _headers,
    );
    final stats = jsonDecode(res.body);

    return AccountInfo(
      serviceName: 'Sia',
      usedStorageBytes: stats['totalObjectsSize'],
    );
  }
}
