import 'dart:math';
import 'dart:typed_data';

import 'package:lib5/lib5.dart';
import 'package:minio/minio.dart';

import 'base.dart';

class S3ObjectStore extends ObjectStore {
  final Minio minio;
  final String bucket;

  final List<String> cdnUrls;

  @override
  final canPutAsync = false;

  S3ObjectStore(
    this.minio,
    this.bucket, {
    required this.cdnUrls,
  }) {
    minio.putBucketCors(
      bucket,
      '''<?xml version="1.0" encoding="UTF-8"?>
<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
   <CORSRule>
      <AllowedOrigin>*</AllowedOrigin>
      <AllowedMethod>GET</AllowedMethod>
      <AllowedMethod>HEAD</AllowedMethod>
      <MaxAgeSeconds>86400</MaxAgeSeconds>
      <AllowedHeader></AllowedHeader>
   </CORSRule>
</CORSConfiguration>''',
    );
  }

  String getObjectKeyForHash(Multihash hash) {
    return '0/${hash.toBase64Url()}';
  }

  @override
  Future<bool> contains(Multihash hash) async {
    final res = await minio.objectExists(
      bucket,
      getObjectKeyForHash(hash),
    );
    return res;
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

    final res = await minio.putObject(
      bucket,
      getObjectKeyForHash(hash),
      data,
      // TODO Make this configurable
      chunkSize: 256 * 1024 * 1024,
    );
    if (res.isEmpty) {
      throw 'Upload failed';
    }
  }

/*   @override
  Future<String> putAsyncUpload(Stream<Uint8List> data) async {
    final path = 'uploading-cache/${generateUID()}';
    final res = await minio.putObject(
      bucket,
      path,
      data,
      onProgress: (bytes) {},
    );
    if (res.isEmpty) {
      throw 'Upload failed';
    }
    return path;
  }

  @override
  Future<void> putAsyncFinalize(String key, Multihash hash) async {
    await minio.copyObject(bucket, getObjectKeyForHash(hash), key);
    await minio.removeObject(bucket, key);
  } */

  final _random = Random();

  @override
  Future<String> provide(Multihash hash) {
    if (cdnUrls.isNotEmpty) {
      final String cdnUrl;
      if (cdnUrls.length == 1) {
        cdnUrl = cdnUrls.first;
      } else {
        cdnUrl = cdnUrls[_random.nextInt(cdnUrls.length)];
      }
      return Future.value(
        '$cdnUrl${getObjectKeyForHash(hash)}',
      );
    }

    return minio.presignedGetObject(
      bucket,
      getObjectKeyForHash(hash),
      expires: 86400, // TODO Configurable
    );
  }

  @override
  Future<void> delete(Multihash hash) {
    return minio.removeObject(bucket, getObjectKeyForHash(hash));
  }
}
