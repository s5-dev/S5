import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart';
import 'package:messagepack/messagepack.dart';
import 'package:mime/mime.dart';
import 'package:minio/minio.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:tint/tint.dart';

import 'package:s5_server/crypto/blake3.dart';
import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/http_api/http_api.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/cid.dart';
import 'package:s5_server/registry/registry.dart';
import 'package:s5_server/service/cache_cleaner.dart';
import 'package:s5_server/service/p2p.dart';
import 'package:s5_server/store/local.dart';

import 'constants.dart';
import 'crypto/ed25519.dart';
import 'model/file_upload_result.dart';
import 'model/metadata.dart';
import 'model/multihash.dart';
import 'store/base.dart';
import 'store/s3.dart';
import 'util/bytes.dart';

class S5Node {
  final Map<String, dynamic> config;

  final Logger logger;

  S5Node(
    this.config,
    this.logger,
  );

  final client = Client();

  late final Box<Map> objectsBox;

  final rawFileUploadPool = Pool(16);

  final metadataCache = <String, Metadata>{};

  ObjectStore? store;
  late bool exposeStore;

  late final RegistryService registry;
  late final P2PService p2p;

  bool checkForB3CLI() {
    try {
      final res = Process.runSync('b3sum', ['--version']);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  late bool b3SumCliAvailable;

  Future<void> start() async {
    Hive.init(config['database']['path']);

    objectsBox = await Hive.openBox('objects');

    p2p = P2PService(this);

    p2p.nodeKeyPair = await ed25519.newKeyPairFromSeed(
      sha512256.convert(utf8.encode(config['keypair']['seed'])).bytes,
    );

    await p2p.init();

    logger.info('${'NODE ID'.bold()}: ${p2p.localNodeId.green()}');

    logger.info('');

    b3SumCliAvailable = checkForB3CLI();

    if (b3SumCliAvailable) {
      logger.info('using b3sum CLI for improved hash performance'.green());
    }

    runObjectGarbageCollector();

    registry = RegistryService(this);
    await registry.init();

    final cachePath = config['cache']['path']!;

    final cacheCleaner = CacheCleaner(Directory(cachePath), logger);

    cacheCleaner.start();

    exposeStore = config['store']?['expose'] ?? true;

    final s3Config = config['store']?['s3'];
    final localConfig = config['store']?['local'];
    final arweaveConfig = config['store']?['arweave'];

    if (s3Config != null && localConfig != null && arweaveConfig != null) {
      throw 'Only one store can be active at the same time';
    }

    if (s3Config != null) {
      store = S3ObjectStore(
        Minio(
          endPoint: s3Config['endpoint'],
          accessKey: s3Config['accessKey'],
          secretKey: s3Config['secretKey'],
        ),
        s3Config['bucket'],
      );
    }

    // ! Arweave is disabled, see pubspec.yaml
/*     if (arweaveConfig != null) {
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
          'Using Arweave wallet ${await (store as ArweaveObjectStore).wallet.getAddress()}');
    } */

    if (localConfig != null) {
      store = LocalObjectStore(
        Directory(localConfig['path']!),
        localConfig['http'],
      );
    }

    await p2p.start();

    final httpAPIServer = HttpAPIServer(this);

    await httpAPIServer.start(cachePath);

    runStatsService();
  }

  void runStatsService() {
    if (store == null) return;

    String? lastState;
    Stream.periodic(Duration(seconds: 10)).listen((event) async {
      final dk = Uint8List(32);

      final str = json.encode(
        {
          'name': config['name'],
          'peers': [
            for (final p in p2p.peers.values) p.id,
          ]
        },
      );
      if (lastState == str) {
        return;
      }
      lastState = str;

      final cid = await uploadRawFile(Uint8List.fromList(
        utf8.encode(
          str,
        ),
      ));
      registry.setEntryHelper(
        p2p.nodeKeyPair,
        p2p.nodeIdBinary,
        dk,
        cid.toRegistryEntry(),
      );
    });
  }

  Future<Uint8List> downloadBytesByHash(Multihash hash) async {
    // TODO Use better cache path
    final hashFile = File(
      join(
        config['cache']['path']!,
        'raw',
        hash.toBase32(),
      ),
    );
    if (hashFile.existsSync()) {
      return hashFile.readAsBytes();
    }

    final dlUriProvider = DownloadUriProvider(this, hash);

    dlUriProvider.start();

    while (true) {
      final dlUri = await dlUriProvider.next();

      logger.verbose('[try] ${dlUri.uri}');

      try {
        final res = await client
            .get(dlUri.uri)
            .timeout(Duration(seconds: 30)); // TODO Adjust timeout

        if (!ensureIntegrity(hash, res.bodyBytes)) {
          throw 'Integrity verification failed';
        }
        dlUriProvider.upvote(dlUri);

        await hashFile.parent.create(recursive: true);
        await hashFile.writeAsBytes(res.bodyBytes);

        return res.bodyBytes;
      } catch (e, st) {
        logger.catched(e, st);

        dlUriProvider.downvote(dlUri);
      }
    }
  }

  final _dnslinkCache = <String, String>{};

  void runObjectGarbageCollector() {
    // TODO Maybe keep peer_ids to know where to ask
    final ts = DateTime.now().millisecondsSinceEpoch;
    int count = 0;
    for (final hash in objectsBox.keys) {
      final map = objectsBox.get(hash)!;
      final nids = map.keys.toList();
      bool hasChanges = false;
      for (final n in nids) {
        if (map[n]['ttl'] < ts) {
          count++;
          map.remove(n);
          hasChanges = true;
        }
      }
      if (map.isEmpty) {
        objectsBox.delete(hash);
      } else if (hasChanges) {
        objectsBox.put(hash, map);
      }
    }
    logger.verbose('[objects] cleaned $count outdated uris');
  }

  Future<String> resolveName(String name) async {
    if (_dnslinkCache.containsKey(name)) {
      return _dnslinkCache[name]!;
    }

    final res = await getS5EntriesForName('_dnslink.$name');
    if (res.isNotEmpty) {
      _dnslinkCache[name] = res.first;
      return res.first;
    }

    final res2 = await getS5EntriesForName(name);
    if (res2.isNotEmpty) {
      _dnslinkCache[name] = res2.first;
      return res2.first;
    }
    throw 'No valid S5 dnslink record found for "$name"';
  }

  // TODO Use Lume DNS
  Future<List<String>> getS5EntriesForName(String name) async {
    final res = await client.get(
      Uri.https(
        'easyhandshake.com:8053',
        '/dns-query',
        {
          'name': name,
          'type': 'TXT',
        },
      ),
    );

    final List<String> results = json
            .decode(res.body)['Answer']
            ?.map<String>((m) => (m['data'] as String).split('"')[1])
            ?.toList() ??
        <String>[];

    return results
        .where((r) => r.startsWith('dnslink=/s5/'))
        .map<String>((r) => r.substring(12))
        .toList();
  }

  void addDownloadUri(Multihash hash, String nodeId, String url, int ttl) {
    final val = objectsBox.get(hash.toBase64Url()) ?? {};
    val[nodeId] = {
      'uri': url,
      'ttl': ttl,
    };
    objectsBox.put(hash.toBase64Url(), val);
  }

  Map<String, Uri> getDownloadUrisFromDB(Multihash hash) {
    final uris = <String, Uri>{};
    final val = objectsBox.get(hash.toBase64Url()) ?? {};
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final e in val.entries) {
      if (e.value['ttl'] < ts) {
      } else {
        uris[e.key] = Uri.parse(
          e.value['uri'],
        );
      }
    }

    return uris;
  }

  Future<void> fetchHashLocally(Multihash hash) async {
    if (store != null) {
      if (await store!.contains(hash)) {
        final url = await store!.provide(hash);

        addDownloadUri(
          hash,
          p2p.localNodeId,
          url,
          DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
        );
      }
    }
  }

  Future<String> uploadMemoryFile({
    required String filename,
    required String? contentType,
    required Uint8List data,
  }) async {
    final res = await calculateFileMetadata(
      size: data.length,
      stream: Stream.value(data),
      filename: filename,
      contentType: (contentType != 'application/octet-stream')
          ? contentType
          : lookupMimeType(
                filename,
                headerBytes: data.sublist(0, 32),
              ) ??
              'application/octet-stream',
    );

    await store!.put(res.metadataHash, Stream.value(res.metadata));

    await store!.put(
      res.fileContentHash,
      Stream.value(data),
    );

    return CID(cidTypeMetadataFile, res.metadataHash).encode();
  }

  Future<CID> uploadMemoryDirectory(
    Map<String, Uint8List> paths, {
    String? dirname,
    List<String>? tryFiles,
    Map<int, String>? errorPages,
  }) async {
    final p = Packer();

    p.packInt(metadataMagicByte);
    p.packInt(metadataTypeDirectory);

    p.packString(dirname);

    p.packListLength(tryFiles?.length ?? 0);

    for (final path in tryFiles ?? []) {
      p.packString(path);
    }

    p.packMapLength(errorPages?.length ?? 0);

    for (final e in errorPages?.entries.toList() ?? <MapEntry>[]) {
      p.packInt(e.key);
      p.packString(e.value);
    }

    p.packInt(paths.length);

    final cids = <String, CID>{};
    final futures = <Future>[];

    Future<void> _upload(String path) async {
      cids[path] = await rawFileUploadPool.withResource(
        () => uploadRawFile(
          paths[path]!,
        ),
      );
    }

    for (final path in paths.keys) {
      futures.add(_upload(path));
    }
    await Future.wait(futures);

    for (final path in paths.keys) {
      final bytes = paths[path]!;
      p.packString(path);
      p.packBinary(cids[path]!.toBinary());
      p.packInt(bytes.length);
      p.packString(
        lookupMimeType(
          path.split('/').last,
          headerBytes: bytes.sublist(0, min(32, bytes.length)),
        ),
      );
    }

    final cid = await uploadRawFile(p.takeBytes());

    return CID(cidTypeMetadataDirectory, cid.hash);
  }

  Future<void> deleteFile(CID cid) async {
    if (cid.type == cidTypeRaw) {
      await deleteHash(cid.hash);
    } else if (cid.type == cidTypeMetadataFile) {
      if (!await store!.contains(cid.hash)) {
        return;
      }
      final metadata = await getMetadataByCID(cid);
      if (metadata is! FileMetadata) {
        throw 'Can\'t delete this type of metadata';
      }

      await deleteHash(metadata.contentHash);

      await deleteHash(cid.hash);

      metadataCache.remove(cid.hash.key);
    } else {
      throw 'Can\'t delete this type of CID';
    }
  }

  Future<void> deleteHash(Multihash hash) async {
    objectsBox.delete(hash.toBase64Url());
    await store?.delete(hash);
  }

  Future<void> pinFile(CID cid) async {
    if (cid.type == cidTypeRaw) {
      await pinHash(cid.hash);
    } else if (cid.type == cidTypeMetadataFile) {
      // TODO Cache metadata when fetching it here
      await pinHash(cid.hash);

      final metadata = await getMetadataByCID(cid) as FileMetadata;

      await pinHash(metadata.contentHash);
    } else {
      throw 'Can\'t pin this type of CID';
    }
  }

  Future<void> pinHash(Multihash hash) async {
    if (await store!.contains(hash)) {
      return;
    }
    final bytes = await downloadBytesByHash(hash);
    await store!.put(hash, Stream.value(bytes));
  }

  Future<Metadata> getMetadataByCID(CID cid) async {
    final hash = cid.hash;

    late final Metadata metadata;

    if (metadataCache.containsKey(hash.key)) {
      metadata = metadataCache[hash.key]!;
    } else {
      final bytes = await downloadBytesByHash(hash);
      if (cid.type == cidTypeMetadataFile) {
        metadata = decodeFileMetadata(bytes);
      } else if (cid.type == cidTypeMetadataDirectory) {
        metadata = decodeDirectoryMetadata(bytes);
      } else {
        throw 'Unsupported metadata format';
      }
      metadataCache[hash.key] = metadata;
    }
    return metadata;
  }

  Future<CID> uploadRawFile(Uint8List data) async {
    if (data.length > 16 * 1024 * 1024) {
      throw 'Raw files only support a maximum size of 16 MiB';
    }
    final hash = Multihash(Uint8List.fromList(mhashBlake3 + BLAKE3.hash(data)));

    await store!.put(
      hash,
      Stream.value(data),
    );

    return CID(cidTypeRaw, hash);
  }

  Future<CID> uploadLocalFile(File file) async {
    final filename = basename(file.path);

/*     if (store!.canPutAsync) {
      logger.verbose('using async upload strategy');

      final size = file.lengthSync();

      final contentType = lookupMimeType(
        filename,
        headerBytes: await file.openRead(0, 32).single,
      );

      final stream = file
          .openRead()
          .map(
            (event) => Uint8List.fromList(event),
          )
          .asBroadcastStream();

      final future = store!.putAsyncUpload(
        stream,
      );

      final res = await calculateFileMetadata(
        size: size,
        stream: stream,
        filename: filename,
        contentType: contentType,
        file: file,
      );

      await store!.put(res.metadataHash, Stream.value(res.metadata));

      final cacheKey = await future;

      await store!.putAsyncFinalize(cacheKey, res.fileContentHash);

      return CID(cidTypeMetadata, res.metadataHash).encode();
    } else { */

    final res = await calculateFileMetadata(
      size: file.lengthSync(),
      stream: file.openRead(),
      filename: filename,
      contentType: lookupMimeType(
        filename,
        headerBytes: await file.openRead(0, 32).single,
      ),
      file: file,
    );

    await store!.put(res.metadataHash, Stream.value(res.metadata));

    await store!.put(
      res.fileContentHash,
      file.openRead().map((event) => Uint8List.fromList(event)),
    );

    return CID(cidTypeMetadataFile, res.metadataHash);
  }

  Future<FileUploadResult> calculateFileMetadata({
    required int size,
    required Stream<List<int>> stream,
    String? filename,
    String? contentType,
    File? file,
  }) async {
    final p = Packer();

    p.packInt(metadataMagicByte);

    p.packInt(metadataTypeFile);

    p.packInt(size);

    p.packString(filename);
    p.packString(contentType);

    p.packInt(defaultChunkSize);

    p.packBinary(mhashBlake3);

    final hashes = <int>[];

    final Uint8List fullHash;

    if (b3SumCliAvailable && file != null) {
      Uint8List hashFromStdout(String s) {
        final list = hex.decode(s.split(' ').first);
        if (list.length != 32) {
          throw 'Invalid hash length';
        }
        return Uint8List.fromList(list);
      }

      final fullHashRes = await Process.run('b3sum', [file.path]);

      fullHash = hashFromStdout(fullHashRes.stdout);

      final queue = <int>[];

      Future<void> calculateHash() async {
        final end = min(queue.length, defaultChunkSize);

        final hash = BLAKE3.hash(Uint8List.fromList(queue.sublist(0, end)));

        hashes.addAll(hash);

        queue.removeRange(0, end);
      }

      await for (final chunk in stream) {
        queue.addAll(chunk);
        while (queue.length >= defaultChunkSize) {
          await calculateHash();
        }
      }
      if (queue.isNotEmpty) {
        await calculateHash();
      }
    } else {
      final queue = <int>[];

      final output = Uint8List(32);

      final ctx = HashContext();

      ctx.reset();

      void calculateHash() {
        final end = min(queue.length, defaultChunkSize);

        final hash = BLAKE3.hash(Uint8List.fromList(queue.sublist(0, end)));

        hashes.addAll(hash);

        queue.removeRange(0, end);
      }

      await for (final chunk in stream) {
        ctx.update(Uint8List.fromList(chunk));

        queue.addAll(chunk);
        while (queue.length >= defaultChunkSize) {
          calculateHash();
        }
      }
      if (queue.isNotEmpty) {
        calculateHash();
      }

      ctx.finalize(output);
      fullHash = output;
    }

    p.packBinary(fullHash);

    p.packBinary(hashes);
    final metadata = p.takeBytes();

    return FileUploadResult(
      fileContentHash: Multihash(Uint8List.fromList(mhashBlake3 + fullHash)),
      metadataHash:
          Multihash(Uint8List.fromList(mhashBlake3 + BLAKE3.hash(metadata))),
      metadata: metadata,
    );
  }

  FileMetadata decodeFileMetadata(Uint8List bytes) {
    final u = Unpacker(bytes);

    final magicByte = u.unpackInt();
    if (magicByte != metadataMagicByte) {
      throw 'Invalid metadata: Unsupported magic byte';
    }
    final typeAndVersion = u.unpackInt();
    if (typeAndVersion != metadataTypeFile) {
      throw 'Invalid metadata: Wrong metadata type';
    }
    final size = u.unpackInt();

    final filename = u.unpackString();
    final contentType = u.unpackString();

    final chunkSize = u.unpackInt();

    final mhashPrefix = u.unpackBinary();
    final contentHash = Multihash(
      Uint8List.fromList(mhashPrefix + u.unpackBinary()),
    );

    final chunkHashes = <Multihash>[];

    final bin = u.unpackBinary();

    for (int i = 0; i < bin.length; i += 32) {
      chunkHashes.add(
        Multihash(
          Uint8List.fromList(mhashPrefix + bin.sublist(i, i + 32)),
        ),
      );
    }

    return FileMetadata(
      contentHash: contentHash,
      size: size ?? 0,
      contentType: contentType,
      filename: filename,
      chunkSize: chunkSize!,
      chunkHashes: chunkHashes,
    );
  }

  // TODO Maybe use correct msgpack format
  DirectoryMetadata decodeDirectoryMetadata(Uint8List bytes) {
    final u = Unpacker(bytes);

    final magicByte = u.unpackInt();
    if (magicByte != metadataMagicByte) {
      throw 'Invalid metadata: Unsupported magic byte';
    }
    final typeAndVersion = u.unpackInt();
    if (typeAndVersion != metadataTypeDirectory) {
      throw 'Invalid metadata: Wrong metadata type';
    }

    final dirname = u.unpackString();

    final tryFiles = u.unpackList().cast<String>();

    final errorPages = u.unpackMap().cast<int, String>();

    final length = u.unpackInt()!;

    final dm = DirectoryMetadata(
      dirname: dirname,
      tryFiles: tryFiles,
      errorPages: errorPages,
      paths: {},
    );

    for (int i = 0; i < length; i++) {
      dm.paths[u.unpackString()!] = DirectoryMetadataFileReference(
        cid: CID.fromBytes(Uint8List.fromList(u.unpackBinary())),
        size: u.unpackInt()!,
        contentType: u.unpackString(),
      );
    }
    return dm;
  }
}
