import 'dart:io';

import 'package:http/http.dart';
import 'package:minio/minio.dart';

import 'package:s5_server/node.dart';

import 'base.dart';
import 'local.dart';
import 'pixeldrain.dart';
import 's3.dart';
import 'sia.dart';
import 'ipfs.dart';
import 'webdav.dart';

Map<String, ObjectStore> createStoresFromConfig(
  Map<String, dynamic> config, {
  required Client httpClient,
  required S5Node node,
}) {
  final s3Config = config['store']?['s3'];
  final localConfig = config['store']?['local'];
  final siaConfig = config['store']?['sia'];
  final pixeldrainConfig = config['store']?['pixeldrain'];
  final arweaveConfig = config['store']?['arweave'];
  final estuaryConfig = config['store']?['estuary'];
  final ipfsStorageConfig = config['store']?['ipfsstorage'];
  final webdavStorageConfig = config['store']?['webdavstorage'];

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

  if (ipfsStorageConfig != null) {
    stores['ipfsstorage'] = IpfsObjectStore(
      ipfsStorageConfig['gatewayUrl'],
      ipfsStorageConfig['apiUrl'],
      ipfsStorageConfig['token'],
    );
  }

  if (webdavStorageConfig != null) {
    stores['webdavstorage'] = WebDAVObjectStore(
      webdavStorageConfig['baseUrl'],
      webdavStorageConfig['username'],
      webdavStorageConfig['password'],
      webdavStorageConfig['publicUrl'],
    );
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

  if (siaConfig != null) {
    stores['sia'] = SiaObjectStore(
      workerApiUrl: siaConfig['workerApiUrl']!,
      apiPassword: siaConfig['apiPassword']!,
      downloadUrls: [siaConfig['downloadUrl']!],
      httpClient: httpClient,
    );
  }
  return stores;
}
