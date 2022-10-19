import 'dart:typed_data';

import 'multihash.dart';

class FileUploadResult {
  final Multihash fileContentHash;
  final Multihash metadataHash;
  final Uint8List metadata;

  FileUploadResult({
    required this.fileContentHash,
    required this.metadataHash,
    required this.metadata,
  });
}
