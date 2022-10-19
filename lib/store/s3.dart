import 'dart:typed_data';

import 'package:minio/minio.dart';
import 'package:s5_server/model/multihash.dart';
import 'package:s5_server/util/uid.dart';

import 'base.dart';

class S3ObjectStore extends ObjectStore {
  final Minio minio;
  final String bucket;

  @override
  final canPutAsync = true;

  S3ObjectStore(this.minio, this.bucket) {
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

  @override
  Future<bool> contains(Multihash hash) async {
    final res = await minio.objectExists(
      bucket,
      hash.toBase64Url(),
    );
    return res;
  }

  @override
  Future<void> put(Multihash hash, Stream<Uint8List> data) async {
    if (await contains(hash)) {
      return;
    }

    final res = await minio.putObject(
      bucket,
      hash.toBase64Url(),
      data,
      onProgress: (bytes) {
        // TODO progress events
      },
    );
    if (res.isEmpty) {
      throw 'Upload failed';
    }
  }

  @override
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
    await minio.copyObject(bucket, hash.toBase64Url(), key);
    await minio.removeObject(bucket, key);
  }

  @override
  Future<String> provide(Multihash hash) {
    return minio.presignedGetObject(bucket, hash.toBase64Url());
  }

  @override
  Future<void> delete(Multihash hash) {
    return minio.removeObject(bucket, hash.toBase64Url());
  }
}
