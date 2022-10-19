import 'package:s5_server/constants.dart';
import 'package:s5_server/model/cid.dart';

import 'multihash.dart';

class FileMetadata extends Metadata {
  final Multihash contentHash;
  final String? filename;
  final String? contentType;
  final int size;
  final int chunkSize;
  final List<Multihash> chunkHashes;

  String get contentCID => CID(cidTypeRaw, contentHash).encode();

  FileMetadata({
    required this.contentHash,
    required this.filename,
    required this.contentType,
    required this.size,
    required this.chunkSize,
    required this.chunkHashes,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'file',
        'filename': filename,
        'contentType': contentType,
        'size': size,
        'chunkSize': chunkSize,
        'contentCID': contentCID,
        'contentHash': contentHash.toBase64Url(),
        'chunkHashes': chunkHashes.map((e) => e.toBase64Url()).toList(),
      };
}

class DirectoryMetadata extends Metadata {
  final String? dirname;

  final List<String> tryFiles;
  final Map<int, String> errorPages;

  final Map<String, DirectoryMetadataFileReference> paths;

  DirectoryMetadata({
    required this.dirname,
    required this.tryFiles,
    required this.errorPages,
    required this.paths,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'directory',
        'dirname': dirname,
        'tryFiles': tryFiles,
        'errorPages':
            errorPages.map((key, value) => MapEntry(key.toString(), value)),
        'paths': paths,
      };
}

class DirectoryMetadataFileReference {
  final String? contentType;
  final int size;
  final CID cid;

  DirectoryMetadataFileReference({
    required this.cid,
    required this.size,
    required this.contentType,
  });

  Map<String, dynamic> toJson() => {
        'cid': cid.encode(),
        'size': size,
        'contentType': contentType,
      };
}

abstract class Metadata {
  Map<String, dynamic> toJson();
}
