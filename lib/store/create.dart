import 'dart:io';

import 'package:http/http.dart';
import 'package:minio/minio.dart';

import 'package:s5_server/node.dart';

import 'base.dart';
import 'fs_provider.dart';
import 'ipfs.dart';
import 'local.dart';
import 'pixeldrain.dart';
import 's3.dart';
import 'sia.dart';

Map<String, ObjectStore> createStoresFromConfig(
  Map<String, dynamic> config, {
  required Client httpClient,
  required S5Node node,
}) {
  final s3Config = config['store']?['s3'];
  final localConfig = config['store']?['local'];
  final siaConfig = config['store']?['sia'];
  final pixeldrainConfig = config['store']?['pixeldrain'];
  final ipfsConfig = config['store']?['ipfs'];
  final fileSystemConfig = config['store']?['fs'];

  final arweaveConfig = config['store']?['arweave'];
  final estuaryConfig = config['store']?['estuary'];

  final stores = <String, ObjectStore>{};

  if (s3Config != null) {
    stores['s3'] = S3ObjectStore(
      Minio(
        endPoint: s3Config['endpoint'],
        accessKey: s3Config['accessKey'],
        secretKey: s3Config['secretKey'],
      ),
      s3Config['bucket'],
      cdnUrls: s3Config['cdnUrls']?.cast<String>() ?? <String>[],
      uploadRequestChunkSize:
          s3Config['uploadRequestChunkSize'] ?? 256 * 1024 * 1024,
      downloadUrlExpiryInSeconds:
          s3Config['downloadUrlExpiryInSeconds'] ?? 86400,
    );
  }

  if (pixeldrainConfig != null) {
    stores['pixeldrain'] = PixeldrainObjectStore(pixeldrainConfig['apiKey']);
  }

  /* if (arweaveConfig != null) {
      store = ArweaveObjectStore(
        Arweave(
          gatewayUrl: Uri.parse(
            arweaveConfig['gatewayUrl'],
          ),
        ),
        Wallet.fromJwk(
          json.decode(
            File(arweaveConfig['walletPath']).readAsStringSync(),
          ),
        ),
      );

      logger.info(
        'Using Arweave wallet ${await (store as ArweaveObjectStore).wallet.getAddress()}',
      );
    } */

  if (localConfig != null) {
    stores['local'] = LocalObjectStore(
      Directory(localConfig['path']!),
      localConfig['http'],
    );
  }

  if (ipfsConfig != null) {
    stores['ipfs'] = IPFSObjectStore(
      ipfsConfig['gatewayUrl'],
      ipfsConfig['apiUrl'],
      ipfsConfig['apiAuthorizationHeader'],
    );
  }

  /* if (metadataBridgeConfig != null) {
      stores['bridge'] = MetadataBridgeObjectStore(
          crypto: crypto,
      );
    } */

  /* if (estuaryConfig != null) {
      store = EstuaryObjectStore(
        apiUrl: estuaryConfig['apiUrl'] ?? 'https://api.estuary.tech',
        apiKey: estuaryConfig['apiKey'],
        httpClient: client,
      );
    } */

  if (fileSystemConfig != null) {
    stores['fs'] = FileSystemProviderObjectStore(node, localDirectories: [
      // TODO Configure directories
      Directory('/public'),
    ]);
  }

  if (siaConfig != null) {
    final String workerApiUrl = siaConfig['workerApiUrl']!;
    stores['sia'] = SiaObjectStore(
      workerApiUrl: workerApiUrl,
      busApiUrl: siaConfig['busApiUrl'] == null
          ? (workerApiUrl.substring(0, workerApiUrl.length - 11) + '/api/bus')
          : siaConfig['busApiUrl'],
      apiPassword: siaConfig['apiPassword']!,
      downloadUrls: [siaConfig['downloadUrl']!],
      bucket: siaConfig['bucket'] ?? 'default',
      httpClient: httpClient,
    );
  }
  return stores;
}
