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
  Future<void> init() async {
    final headers = { "Authorization": "Basic $token" };

    final uri = _getApiUri('/v0/files/mkdir?arg=/s5data&parents=true');
    final res = await http.post(Uri.parse('$uri'), headers: headers);

    final uri1 = _getApiUri('/v0/files/ls?arg=/s5data&long=true');
    final res1 = await http.post(Uri.parse('$uri1'), headers: headers);
    final body = json.decode(res1.body);

//    print(res1.body);
//    print(res1.statusCode);
//    print(body['Entries'].length);
//    print(body.runtimeType);

    if (body['Entries'] != null) {
      var num = body['Entries'].length;

      for (int i = 0; i < num; i++) {
        var hname = body['Entries'][i]['Name'];
        var hhash = body['Entries'][i]['Hash'];

        if (hname.endsWith('.obao')) {
          var sname = hname.split('.');
          availableBaoOutboardHashes[Multihash.fromBase64Url(sname[0])] = '${hhash}';
        } else {
          availableHashes[Multihash.fromBase64Url(hname)] = '${hhash}';
        }
      }
      print(' ');
      print('availableBaoOutboardHashes: ');
      print(availableBaoOutboardHashes);
      print(' ');
      print('availableHashes: ');
      print(availableHashes);
      print(' ');
    }
  }

  @override
  final uploadsSupported = true;

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

    final headers1 = { "Authorization": "Basic $token" };
    final uri1 = _getApiUri('/v0/files/cp?arg=/ipfs/$ipfsHash2&arg=/s5data/${getObjectKeyForHash(hash)}');
    final res1 = await http.post(Uri.parse('$uri1'), headers: headers1);

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

    final headers1 = { "Authorization": "Basic $token" };
    final uri1 = _getApiUri('/v0/files/cp?arg=/ipfs/$ipfsHash&arg=/s5data/${getObjectKeyForHash(hash)}.obao');
    final res1 = await http.post(Uri.parse('$uri1'), headers: headers1);

    availableBaoOutboardHashes[hash] = '$ipfsHash';
  }

  @override
  Future<void> delete(Multihash hash) async {
    final uri = _getApiUri('/v0/pin/rm?arg=');
    final uri2 = _getApiUri('/v0/files/rm?arg=/s5data/');

    if (availableBaoOutboardHashes.containsKey(hash)) {
      final res = await http.post(
        Uri.parse('$uri${availableBaoOutboardHashes[hash]!}'),
        headers: { "Authorization": "Basic $token" },
      );
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res.body}';
      }

      final res2 = await http.post(
        Uri.parse('$uri2${hash}.obao'),
        headers: { "Authorization": "Basic $token" },
      );
      if (res2.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res2.body}';
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

      final res2 = await http.post(
        Uri.parse('$uri2${hash}'),
        headers: { "Authorization": "Basic $token" },
      );
      if (res2.statusCode != 200) {
        throw 'HTTP ${res.statusCode}: ${res2.body}';
      }

      availableHashes.remove(hash);
    }
  }
}
