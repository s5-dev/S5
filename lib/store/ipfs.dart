import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'base.dart';

class IpfsObjectStore extends ObjectStore {
  final String gatewayUrl;
  final String apiUrl;
  final String? token;

  IpfsObjectStore(this.gatewayUrl, this.apiUrl, this.token);

  var availableHashes = <Multihash, String>{};
  var availableBaoOutboardHashes = <Multihash, String>{};

  @override
  Future<void> init() async {
    final headers = {'Authorization': 'Basic $token'};
    final filesMkdirUri = _getApiUri('/v0/files/mkdir?arg=/s5data&parents=true');
    await http.post(filesMkdirUri, headers: headers);

    final filesLsUri = _getApiUri('/v0/files/ls?arg=/s5data&long=true');
    final res = await http.post(filesLsUri, headers: headers);
    final body = json.decode(res.body);

    for (final entry in body['Entries'] ?? []) {
      final hname = entry['Name'], hhash = entry['Hash'];
      final multihash = hname.endsWith('.obao') ? hname.split('.').first : hname;
      (hname.endsWith('.obao') ? availableBaoOutboardHashes : availableHashes)[Multihash.fromBase64Url(multihash)] = hhash;
    }
  }

  @override
  final uploadsSupported = true;

  Uri _getApiUri(String path) {
    return Uri.parse('$apiUrl/api$path');
  }

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '${hash.toBase64Url()}/$ext';
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
        final outboardUrl = '$gatewayUrl/ipfs/${availableBaoOutboardHashes[hash]!}';
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

    final addPinUri = _getApiUri('/v0/add?pin=true&recursive=true');
    final request = http.MultipartRequest('POST', addPinUri);
    request.files.add(http.MultipartFile(
      'file',
      data,
      length,
      filename: '${getObjectKeyForHash(hash)}',
    ));
    if (token != null) {
      request.headers['Authorization'] = 'Basic $token';
    }
    final response = await request.send();
    if (response.statusCode != 200) {
      throw Exception('IPFS upload failed: invalid response');
    }
    final responseJson = json.decode(await response.stream.bytesToString());
    final ipfsHash = responseJson['Hash'];

    final headers = { "Authorization": "Basic $token" };
    final filesAddUri = _getApiUri('/v0/files/cp?arg=/ipfs/$ipfsHash&arg=/s5data/${getObjectKeyForHash(hash)}');
    await http.post(Uri.parse('$filesAddUri'), headers: headers);

    availableHashes[hash] = '$ipfsHash';
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }

    final addPinUri = _getApiUri('/v0/add?pin=true&recursive=true');
    final request = http.MultipartRequest('POST', addPinUri);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      outboard,
      filename: '${getObjectKeyForHash(hash)}.obao',
    ));
    if (token != null) {
      request.headers['Authorization'] = 'Basic $token';
    }
    final response = await request.send();
    if (response.statusCode != 200) {
      throw Exception('IPFS upload obao failed: invalid response');
    }
    final responseJson = json.decode(await response.stream.bytesToString());
    final ipfsHash = responseJson['Hash'];

    final headers = { "Authorization": "Basic $token" };
    final filesAddUri = _getApiUri('/v0/files/cp?arg=/ipfs/$ipfsHash&arg=/s5data/${getObjectKeyForHash(hash)}.obao');
    await http.post(Uri.parse('$filesAddUri'), headers: headers);

    availableBaoOutboardHashes[hash] = '$ipfsHash';
  }

  @override
  Future<void> delete(Multihash hash) async {
    final pinRmUri = _getApiUri('/v0/pin/rm?arg=');
    final filesRmUri = _getApiUri('/v0/files/rm?arg=/s5data/');
    final headers = {"Authorization": "Basic $token"};

    if (availableBaoOutboardHashes.containsKey(hash)) {
      final res = await http.post(Uri.parse('$pinRmUri${availableBaoOutboardHashes[hash]!}'), headers: headers);
      final res2 = await http.post(Uri.parse('$filesRmUri${hash}.obao'), headers: headers);
      if (res.statusCode != 200 || res2.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}, ${res2.statusCode}: ${res2.body}';
      }
      availableBaoOutboardHashes.remove(hash);
    }

    if (availableHashes.containsKey(hash)) {
      final res = await http.post(Uri.parse('$pinRmUri${availableHashes[hash]!}'), headers: headers);
      final res2 = await http.post(Uri.parse('$filesRmUri${hash}'), headers: headers);
      if (res.statusCode != 200 || res2.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}, ${res2.statusCode}: ${res2.body}';
      }
      availableHashes.remove(hash);
    }
  }
}
