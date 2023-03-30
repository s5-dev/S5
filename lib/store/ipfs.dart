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
    // No initialization required for ipfs
  }

  @override
  final uploadsSupported = true;

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '${hash.toBase58()}/$ext';
    }
    return hash.toBase58();
  }

  Uri _getApiUri(String path) {
    return Uri.parse('$apiUrl/api$path');
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
//    final uri = _getApiUri('/v0/object/stat/${availableHashes[hash]!}');
//    final res = await http.head(Uri.parse('$uri'));
//    return res.statusCode == 200;
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

    final url = _getApiUri('/v0/add?pin=true&recursive=true');

    final request = http.MultipartRequest('POST', url);
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
    final responseBody = await response.stream.bytesToString();
//    print(responseBody);

    final responseJson = json.decode(responseBody);
    if (responseJson.containsKey('Hash')) {
      final ipfsHash = responseJson['Hash'];
    } else {
      throw Exception('IPFS upload failed: invalid response');
    }
    if (response.statusCode != 200) {
      throw Exception('IPFS upload failed: invalid response');
    }

    final responseJson1 = json.decode(responseBody);
    final ipfsHash2 = responseJson1['Hash'];

    availableHashes = { hash: '$ipfsHash2' };
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    if (availableBaoOutboardHashes.containsKey(hash)) {
      return;
    }

    final uri = _getApiUri('/v0/add?pin=true&recursive=true');

    final request = http.MultipartRequest('POST', uri);

    final bytes = http.ByteStream.fromBytes(outboard);
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
      throw Exception('IPFS upload failed: invalid response');
    }
    final responseJson = json.decode(await response.stream.bytesToString());
    final ipfsHash = responseJson['Hash'];

    availableBaoOutboardHashes[hash] = '$ipfsHash';
  }

  @override
  Future<void> delete(Multihash hash) async {
    final uri = _getApiUri('/v0/pin/rm?arg=');

    if (availableBaoOutboardHashes.containsKey(hash)) {
      final res = await http.post(
        Uri.parse('$uri${availableBaoOutboardHashes[hash]!}'),
        headers: { "Authorization": "Basic $token" },
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }

      availableBaoOutboardHashes.remove(hash);
    }

    if (availableHashes.containsKey(hash)) {
      final res = await http.post(
        Uri.parse('$uri${availableHashes[hash]!}'),
        headers: { "Authorization": "Basic $token" },
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }

      availableHashes.remove(hash);
    }
  }
}
