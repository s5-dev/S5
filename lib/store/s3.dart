import 'dart:math';
import 'dart:typed_data';

import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:minio/minio.dart';

import 'base.dart';

class S3ObjectStore extends ObjectStore {
  final Minio minio;
  final String bucket;

  final List<String> cdnUrls;

  final availableHashes = <Multihash>{};
  final availableBaoOutboardHashes = <Multihash>{};

  @override
  Future<void> init() async {
    await for (final page in minio.listObjects(bucket, prefix: '1/')) {
      for (final object in page.objects) {
        if (object.key!.endsWith('.obao')) {
          availableBaoOutboardHashes.add(
            Multihash.fromBase64Url(object.key!.substring(2).split('.')[0]),
          );
        } else {
          availableHashes.add(
            Multihash.fromBase64Url(object.key!.substring(2)),
          );
        }
      }
    }
  }

  @override
  final uploadsSupported = true;

  final int uploadRequestChunkSize;
  final int downloadUrlExpiryInSeconds;

  S3ObjectStore(
    this.minio,
    this.bucket, {
    required this.cdnUrls,
    required this.uploadRequestChunkSize,
    required this.downloadUrlExpiryInSeconds,
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

  String getObjectKeyForHash(Multihash hash, [String? ext]) {
    if (ext != null) {
      return '1/${hash.toBase64Url()}.$ext';
    }
    return '1/${hash.toBase64Url()}';
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
        if (cdnUrls.isNotEmpty) {
          final String cdnUrl;
          if (cdnUrls.length == 1) {
            cdnUrl = cdnUrls.first;
          } else {
            cdnUrl = cdnUrls[_random.nextInt(cdnUrls.length)];
          }

          return StorageLocation(
            type,
            ['$cdnUrl${getObjectKeyForHash(hash)}'],
            calculateExpiry(Duration(hours: 1)),
          );
        } else {
          final fileUrl = await minio.presignedGetObject(
            bucket,
            getObjectKeyForHash(hash),
            expires: downloadUrlExpiryInSeconds,
          );
          if (type == storageLocationTypeFile) {
            return StorageLocation(
              storageLocationTypeFile,
              [fileUrl],
              calculateExpiry(Duration(hours: 1)),
            );
          }

          final outboardUrl = await minio.presignedGetObject(
            bucket,
            getObjectKeyForHash(hash, 'obao'),
            expires: downloadUrlExpiryInSeconds,
          );
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
    }
    throw 'Could not provide hash $hash for types $types';
  }

  // ! writes

  @override
  Future<bool> contains(Multihash hash) async {
    return availableHashes.contains(hash);
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
      chunkSize: uploadRequestChunkSize,
    );
    if (res.isEmpty) {
      throw 'Upload failed';
    }
    availableHashes.add(hash);
  }

  @override
  Future<void> delete(Multihash hash) async {
    if (availableBaoOutboardHashes.contains(hash)) {
      await minio.removeObject(bucket, getObjectKeyForHash(hash, 'obao'));
      availableBaoOutboardHashes.remove(hash);
    }
    await minio.removeObject(bucket, getObjectKeyForHash(hash));
    availableHashes.remove(hash);
  }

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async {
    final res = await minio.putObject(
      bucket,
      getObjectKeyForHash(hash, 'obao'),
      Stream.value(outboard),
    );
    if (res.isEmpty) {
      throw 'Upload failed';
    }
    availableBaoOutboardHashes.add(hash);
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
}
