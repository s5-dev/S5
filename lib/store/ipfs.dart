import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';

import 'package:s5_server/util/expect_status_code.dart';
import 'base.dart';

class IPFSObjectStore extends ObjectStore {
  final String gatewayUrl;
  final String apiUrl;
  final String? authorizationHeader;

  final httpClient = http.Client();

  IPFSObjectStore(this.gatewayUrl, this.apiUrl, this.authorizationHeader);

  var availableHashes = <Multihash, String>{};
  var availableBaoOutboardHashes = <Multihash, String>{};

  late final Map<String, String> authHeaders;

  @override
  Future<void> init() async {
    authHeaders = authorizationHeader == null
        ? {}
        : {'Authorization': authorizationHeader!};

    final mkdirRes = await httpClient.post(
      _getApiUri('/files/mkdir?arg=/s5/blob&parents=true&hash=blake3'),
      headers: authHeaders,
    );
    mkdirRes.expectStatusCode(200);

    final mkdirOutboardRes = await httpClient.post(
      _getApiUri('/files/mkdir?arg=/s5/obao&parents=true&hash=blake3'),
      headers: authHeaders,
    );
    mkdirOutboardRes.expectStatusCode(200);

    final blobListRes = await httpClient.post(
      _getApiUri('/files/ls?arg=/s5/blob&long=true'),
      headers: authHeaders,
    );
    for (final entry in (json.decode(blobListRes.body)['Entries'] ?? [])) {
      final String name = entry['Name'];
      availableHashes[Multihash.fromBase64Url(name)] = entry['Hash'];
    }

    final outboardListRes = await httpClient.post(
      _getApiUri('/files/ls?arg=/s5/obao&long=true'),
      headers: authHeaders,
    );
    for (final entry in (json.decode(outboardListRes.body)['Entries'] ?? [])) {
      final String name = entry['Name'];
      availableBaoOutboardHashes[Multihash.fromBase64Url(name)] = entry['Hash'];
    }
  }

  @override
  final uploadsSupported = true;

  Uri _getApiUri(String path) {
    return Uri.parse('$apiUrl/api/v0$path');
  }

  String getObjectPathForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '/s5/obao/${hash.toBase64Url()}';
    }
    return '/s5/blob/${hash.toBase64Url()}';
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

      final fileUrl = '$gatewayUrl/ipfs/${availableHashes[hash]!}';
      if (type == storageLocationTypeArchive) {
        return StorageLocation(
          storageLocationTypeArchive,
          [],
          calculateExpiry(Duration(days: 1)),
        );
      } else if (type == storageLocationTypeFile) {
        return StorageLocation(
          storageLocationTypeFile,
          [fileUrl],
          calculateExpiry(Duration(hours: 1)),
        );
      } else if (type == storageLocationTypeFull) {
        final outboardUrl =
            '$gatewayUrl/ipfs/${availableBaoOutboardHashes[hash]!}';
        return StorageLocation(
          storageLocationTypeFull,
          [fileUrl, outboardUrl],
          calculateExpiry(Duration(hours: 1)),
        );
      }
    }
    throw 'Could not provide hash $hash for types $types';
  }

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

    final uploadUrl = _getApiUri(
      '/add?quieter=true&chunker=size-1048576&raw-leaves=true&hash=blake3&pin=true',
    );

    final request = http.MultipartRequest('POST', uploadUrl);
    request.files.add(http.MultipartFile(
      'file',
      data,
      length,
    ));
    request.headers.addAll(authHeaders);

    final res = await request.send();
    final body = await res.stream.bytesToString();

    if (res.statusCode != 200) {
      throw Exception('IPFS upload failed: HTTP ${res.statusCode}: $body');
    }
    final String cid = jsonDecode(body)['Hash'];

    final copyRes = await httpClient.post(
      _getApiUri('/files/cp?arg=/ipfs/$cid&arg=${getObjectPathForHash(hash)}'),
      headers: authHeaders,
    );
    copyRes.expectStatusCode(200);
    availableHashes[hash] = cid;
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }

    final uploadUrl = _getApiUri(
      '/add?quieter=true&chunker=size-1048576&raw-leaves=true&hash=blake3&pin=true',
    );

    final request = http.MultipartRequest('POST', uploadUrl);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      outboard,
    ));
    request.headers.addAll(authHeaders);

    final res = await request.send();
    final body = await res.stream.bytesToString();

    if (res.statusCode != 200) {
      throw Exception('IPFS upload failed: HTTP ${res.statusCode}: $body');
    }
    final String cid = jsonDecode(body)['Hash'];

    final copyRes = await httpClient.post(
      _getApiUri(
          '/files/cp?arg=/ipfs/$cid&arg=${getObjectPathForHash(hash, 'obao')}'),
      headers: authHeaders,
    );
    copyRes.expectStatusCode(200);
    availableBaoOutboardHashes[hash] = cid;
  }

  @override
  Future<void> delete(Multihash hash) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      final unpinRes = await httpClient.post(
        _getApiUri('/pin/rm?arg=${availableBaoOutboardHashes[hash]!}'),
        headers: authHeaders,
      );
      unpinRes.expectStatusCode(200);

      final res = await httpClient.post(
        _getApiUri('/files/rm?arg=${getObjectPathForHash(hash, 'obao')}'),
        headers: authHeaders,
      );
      res.expectStatusCode(200);
      availableBaoOutboardHashes.remove(hash);
    }

    if (availableHashes.containsKey(hash)) {
      final unpinRes = await httpClient.post(
        _getApiUri('/pin/rm?arg=${availableHashes[hash]!}'),
        headers: authHeaders,
      );
      unpinRes.expectStatusCode(200);

      final res = await httpClient.post(
        _getApiUri('/files/rm?arg=${getObjectPathForHash(hash)}'),
        headers: authHeaders,
      );
      res.expectStatusCode(200);
      availableHashes.remove(hash);
    }
  }
}