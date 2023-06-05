import 'dart:typed_data';

import 'package:lib5/lib5.dart';

export 'package:s5_server/util/calculate_expiry.dart';

abstract class ObjectStore {
  Future<void> init();

  bool get uploadsSupported;

  // TODO Maybe make canProvide sync

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

  Future<AccountInfo> getAccountInfo() {
    throw UnimplementedError();
  }
}

class AccountInfo {
  final String? userIdentifier;

  final bool isRestricted;
  final String? subscription;
  final String? warning;

  final int usedStorageBytes;
  final int? expiryDays;
  final int? maxFileSize;
  final int? totalStorageBytes;

  AccountInfo({
    this.userIdentifier,
    required this.usedStorageBytes,
    this.isRestricted = false,
    this.warning,
    this.expiryDays,
    this.maxFileSize,
    this.totalStorageBytes,
    this.subscription,
  });
}
