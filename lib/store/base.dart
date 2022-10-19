import 'dart:typed_data';

import 'package:s5_server/model/multihash.dart';

abstract class ObjectStore {
  Future<bool> contains(Multihash hash);
  Future<void> put(Multihash hash, Stream<Uint8List> data);
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
