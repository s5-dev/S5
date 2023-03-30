import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'base.dart';

class WebDAVObjectStore extends ObjectStore {
  final String baseUrl;
  final String? username;
  final String? password;
  final String publicUrl;

  WebDAVObjectStore(this.baseUrl, this.username, this.password, this.publicUrl);

  var availableHashes = <Multihash, String>{};
  var availableBaoOutboardHashes = <Multihash, String>{};

  @override
  Future<void> init() async {
    // No initialization required for WebDAV
  }

  @override
  final uploadsSupported = true;

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '${hash.toBase64Url()}/$ext';
    }
    return hash.toBase64Url();
  }

  Map<String, String> _getHeaders() {
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/octet-stream',
    };
    if (username != "" && password != "") {
      final auth = base64.encode(utf8.encode('$username:$password'));
      headers[HttpHeaders.authorizationHeader] = 'Basic $auth';
    }
    return headers;
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

      final fileUrl = '${publicUrl}${availableHashes[hash]!}';

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

        final outboardUrl = '${publicUrl}${availableBaoOutboardHashes[hash]!}.obao';

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
  Future<void> put(Multihash hash, Stream<Uint8List> data, int length) async {
    if (await contains(hash)) {
      return;
    }

    final request = http.Request('PUT', Uri.parse('$baseUrl${getObjectKeyForHash(hash)}'));

    request.bodyBytes = await data.toList().then((list) => list.expand((x) => x).toList());
//    if (username != "" && password != "") {
      request.headers.addAll(_getHeaders());
//    }
    request.headers[HttpHeaders.contentLengthHeader] = length.toString();

    final response = await request.send();
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw Exception('WebDAV upload failed: HTTP ${response.statusCode}');
    }
    availableHashes = { hash: '${getObjectKeyForHash(hash)}' };
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }

    final request = http.Request('PUT', Uri.parse('$baseUrl${getObjectKeyForHash(hash)}.obao'));

    request.bodyBytes = outboard;
    if (username != "" && password != "") {
      request.headers.addAll(_getHeaders());
    }

    final response = await request.send();
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw Exception('WebDAV upload failed: HTTP ${response.statusCode}');
    }
    availableBaoOutboardHashes[hash] = '${getObjectKeyForHash(hash)}';
  }

  @override
  Future<void> delete(Multihash hash) async {
//    if (availableBaoOutboardHashes.containsKey(hash)) {
      if (username != "" && password != "") {

        final auth = base64.encode(utf8.encode('$username:$password'));

        final res = await http.delete(
          Uri.parse('$baseUrl${getObjectKeyForHash(hash)}.obao'),
          headers: { "Authorization": "Basic $auth" },
        );
        if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 404) {
          throw 'HTTP ${res.statusCode}: ${res.body}';
        }
      } else {
        final res = await http.delete(
          Uri.parse('$baseUrl${getObjectKeyForHash(hash)}.obao'),
        );
        if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 404) {
          throw 'HTTP ${res.statusCode}: ${res.body}';
        }
      }
      availableBaoOutboardHashes.remove(hash);
//    }

//    if (availableHashes.containsKey(hash)) {
      if (username != "" && password != "") {
        final auth = base64.encode(utf8.encode('$username:$password'));

        final res = await http.delete(
          Uri.parse('$baseUrl${getObjectKeyForHash(hash)}'),
          headers: { "Authorization": "Basic $auth" },
        );
        if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 404) {
          throw 'HTTP ${res.statusCode}: ${res.body}';
        }
      } else {
        final res = await http.delete(
          Uri.parse('$baseUrl${getObjectKeyForHash(hash)}'),
        );
        if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 404) {
          throw 'HTTP ${res.statusCode}: ${res.body}';
        }
      }
      availableHashes.remove(hash);
//    }
  }
}
