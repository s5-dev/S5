import 'dart:convert';
import 'package:xml/xml.dart';
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
    final uri = Uri.parse(baseUrl);
    final authn = 'Basic ' + base64Encode(utf8.encode('$username:$password'));
    final request = new http.Request('PROPFIND', uri);
    request.headers['Authorization'] = authn;
    request.headers['Depth'] = '1';
    final response = await request.send();
    final respStr = await response.stream.bytesToString();
    final respXml = XmlDocument.parse(respStr);
    final allHref = respXml
        .findAllElements('d:response')
        .map((e) => e.findAllElements('d:href').first.text)
        .followedBy(respXml
            .findAllElements('D:response')
            .map((e) => e.findAllElements('D:href').first.text))
        .followedBy(respXml
            .findAllElements('a:response')
            .map((e) => e.findAllElements('a:href').first.text));

    for (final href in allHref) {
      final foundFilenames = href.split(uri.path).last;
      if (foundFilenames.endsWith('.obao')) {
        final obaoSplitedFromFilename = foundFilenames.split('.');
        availableBaoOutboardHashes[Multihash.fromBase64Url(obaoSplitedFromFilename[0])] = obaoSplitedFromFilename[0];
      } else if (foundFilenames.isNotEmpty) {
        availableHashes[Multihash.fromBase64Url(foundFilenames)] = foundFilenames;
      }
    }
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
    request.headers.addAll(_getHeaders());
    request.headers[HttpHeaders.contentLengthHeader] = length.toString();

    final response = await request.send();
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw Exception('WebDAV upload failed: HTTP ${response.statusCode}');
    }
    availableHashes[hash] = '${getObjectKeyForHash(hash)}';
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }

    final request = http.Request('PUT', Uri.parse('$baseUrl${getObjectKeyForHash(hash)}.obao'));
    request.bodyBytes = outboard;
    request.headers.addAll(_getHeaders());

    final response = await request.send();
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw Exception('WebDAV upload failed: HTTP ${response.statusCode}');
    }
    availableBaoOutboardHashes[hash] = '${getObjectKeyForHash(hash)}';
  }

  @override
  Future<void> delete(Multihash hash) async {
    final key = getObjectKeyForHash(hash);
    final smallFile = availableHashes.containsKey(hash);
    final outboard = availableBaoOutboardHashes.containsKey(hash);
    final auth = (username?.isNotEmpty == true && password?.isNotEmpty == true)
        ? base64.encode(utf8.encode('$username:$password'))
        : null;
    final uri = Uri.parse('$baseUrl${outboard ? key + '.obao' : key}');
    final smallUri = Uri.parse('$baseUrl${smallFile ? key : key}');

    final res = await http.delete(uri, headers: auth != null ? { 'Authorization': 'Basic $auth' } : null);
    final res2 = await http.delete(smallUri, headers: auth != null ? { 'Authorization': 'Basic $auth' } : null);
    if (![201, 204, 404].contains(res.statusCode)) {
      throw 'HTTP ${res.statusCode}: ${res.body}';
    }
    if (outboard) {
      availableBaoOutboardHashes.remove(hash);
    } else if (smallFile) {
      availableHashes.remove(hash);
    }
  }
}
