import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:http/src/client.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/storage_service.dart';

import 'node.dart';

class S5NodeAPIProviderWithRemoteUpload extends S5APIProviderWithRemoteUpload {
  final S5Node node;

  final Box<Uint8List> deletedCIDs;

  S5NodeAPIProviderWithRemoteUpload(this.node, {required this.deletedCIDs});

  @override
  Client get httpClient => node.client;

  @override
  CryptoImplementation get crypto => node.crypto;

  @override
  Future<Uint8List> downloadRawFile(Multihash hash) =>
      node.downloadBytesByHash(hash);

  @override
  void deleteCID(CID cid) {
    deletedCIDs.add(cid.toBytes());
  }

  @override
  Future<Metadata> getMetadataByCID(CID cid) => node.getMetadataByCID(cid);

  @override
  Future<SignedRegistryEntry?> registryGet(Uint8List pk) =>
      node.registry.get(pk);

  @override
  Stream<SignedRegistryEntry> registryListen(Uint8List pk) =>
      node.registry.listen(pk);

  @override
  Future<void> registrySet(SignedRegistryEntry sre) => node.registry.set(sre);
}
