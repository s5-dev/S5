import 'dart:typed_data';

import 'package:lib5/lib5.dart';

export 'package:s5_server/util/calculate_expiry.dart';

abstract class ObjectStore {
  Future<void> init();

  bool get uploadsSupported;

  // ! used for downloads / p2p requests
  Future<bool> canProvide(
    Multihash hash,
    List<int> types,
  );
  Future<StorageLocation> provide(
    Multihash hash,
    List<int> types,
  );

  // ! used for uploading/storing files

  Future<bool> contains(Multihash hash);
  Future<void> put(
    Multihash hash,
    Stream<Uint8List> data,
    int length,
  );
  Future<void> putBaoOutboardBytes(
    Multihash hash,
    Uint8List outboard,
  );
  Future<void> delete(Multihash hash);
}
