import 'package:lib5/lib5.dart';
import 'dart:typed_data';

import 'package:s5_server/store/base.dart';

class MergedObjectStore extends ObjectStore {
  final Map<String, ObjectStore> stores;

  final Map<String, int> minFileSize = {};
  final Map<String, int> maxFileSize = {};

  MergedObjectStore(this.stores, {Map? allowedUploadSizes}) {
    if (allowedUploadSizes != null) {
      for (final key in allowedUploadSizes.keys) {
        final parts = (allowedUploadSizes[key] as String).split('-');
        if (parts[0].isNotEmpty) {
          minFileSize[key] = int.parse(parts[0]);
        }
        if (parts[1].isNotEmpty) {
          maxFileSize[key] = int.parse(parts[1]);
        }
      }
    }
  }

  @override
  Future<void> init() async {
    for (final store in stores.values) {
      await store.init();
    }
  }

  @override
  bool get uploadsSupported =>
      stores.values.fold(false, (previousValue, element) {
        if (element.uploadsSupported) {
          return true;
        }
        return previousValue;
      });

  // ! downloads

  @override
  Future<StorageLocation> provide(Multihash hash, List<int> types) async {
    return (await _firstWhichCanProvide(hash, types))!.provide(hash, types);
  }

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async {
    return (await _firstWhichCanProvide(hash, types)) != null;
  }

  Future<ObjectStore?> _firstWhichCanProvide(
      Multihash hash, List<int> types) async {
    for (final store in stores.values) {
      if (await store.canProvide(hash, types)) {
        return store;
      }
    }
    return null;
  }

  // ! uploads

  Future<ObjectStore?> _firstWhichContains(Multihash hash) async {
    for (final store in stores.values) {
      if (await store.contains(hash)) {
        return store;
      }
    }
    return null;
  }

  @override
  Future<void> delete(Multihash hash) => stores.values.first.delete(hash);

  ObjectStore? _firstWhichCanUpload(int size) {
    for (final key in stores.keys) {
      if (maxFileSize.containsKey(key)) {
        if (maxFileSize[key]! < size) continue;
      }
      if (minFileSize.containsKey(key)) {
        if (minFileSize[key]! > size) continue;
      }
      return stores[key];
    }
    return null;
  }

  @override
  Future<void> put(Multihash hash, Stream<Uint8List> data, int length) =>
      _firstWhichCanUpload(length)!.put(hash, data, length);

  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) =>
      _firstWhichCanUpload(outboard.length)!
          .putBaoOutboardBytes(hash, outboard);

  @override
  Future<bool> contains(Multihash hash) async {
    return (await _firstWhichContains(hash)) != null;
  }
}
