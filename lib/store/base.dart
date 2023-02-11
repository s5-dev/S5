import 'dart:typed_data';

import 'package:lib5/lib5.dart';

abstract class ObjectStore {
  Future<bool> contains(Multihash hash);
  Future<void> put(
    Multihash hash,
    Stream<Uint8List> data,
    int length,
  );
  Future<String> provide(Multihash hash);
  Future<void> delete(Multihash hash);

  bool get canPutAsync;

  Future<String> putAsyncUpload(Stream<Uint8List> data) {
    throw 'Not implemented';
  }

  Future<void> putAsyncFinalize(String key, Multihash hash) {
    throw 'Not implemented';
  }
}
