import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:http/http.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:messagepack/messagepack.dart';
import 'package:mime/mime.dart';
import 'package:minio/minio.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:tint/tint.dart';

import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/http_api/http_api.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/node_id.dart';
import 'package:s5_server/rust/bridge_definitions.dart';
import 'package:s5_server/service/accounts.dart';
import 'package:s5_server/service/cache_cleaner.dart';
import 'package:s5_server/service/p2p.dart';
import 'package:s5_server/service/registry.dart';
import 'package:s5_server/store/local.dart';

import 'accounts/user.dart';
import 'constants.dart';
import 'store/base.dart';
import 'store/s3.dart';

class S5Node {
  final Map<String, dynamic> config;

  final Logger logger;
  final Rust rust;

  CryptoImplementation crypto;

  S5Node(
    this.config, {
    required this.logger,
    required this.rust,
    required this.crypto,
  });

  late final String cachePath;

  final client = Client();

  late final Box<Map> objectsBox;

  final rawFileUploadPool = Pool(16);

  final metadataCache = <Multihash, Metadata>{};

  ObjectStore? store;
  late bool exposeStore;

  AccountsService? accounts;

  late final RegistryService registry;
  late final P2PService p2p;

  Future<void> start() async {
    if (config['database']?['path'] != null) {
      Hive.init(config['database']['path']);
    }

    objectsBox = await Hive.openBox('s5-objects');

    p2p = P2PService(this);

    p2p.nodeKeyPair = await crypto.newKeyPairEd25519(
      seed: base64Url.decode(config['keypair']['seed']),
    );

    await p2p.init();

    logger.info('${'NODE ID'.bold()}: ${p2p.localNodeId.toString().green()}');

    logger.info('');

    runObjectGarbageCollector();

    registry = RegistryService(this);
    await registry.init();

    cachePath = config['cache']['path']!;

    final cacheCleaner = CacheCleaner(Directory(cachePath), logger);

    cacheCleaner.start();

    exposeStore = config['store']?['expose'] ?? true;

    final s3Config = config['store']?['s3'];
    final localConfig = config['store']?['local'];
    final siaConfig = config['store']?['sia'];
    final arweaveConfig = config['store']?['arweave'];

    if (s3Config != null &&
        localConfig != null &&
        arweaveConfig != null &&
        siaConfig != null) {
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
        cdnUrls: s3Config['cdnUrls'] ?? [],
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
/*     if (siaConfig != null) {
      store = SiaObjectStore(
        siaConfig['renterd_api_addr']!,
        siaConfig['renterd_api_password']!,
        siaConfig['http'],
        crypto: crypto,
      );
    } */

    if (store == null) {
      exposeStore = false;
    }

    await p2p.start();

    final accountsConfig = config['accounts'];
    if (accountsConfig?['enabled'] == true) {
      accounts = AccountsService(
        accountsConfig,
        logger: logger,
        crypto: crypto,
      );
      await accounts!.init();
    }

    final httpAPIServer = HttpAPIServer(this);

    await httpAPIServer.start(cachePath);

    // runStatsService();
  }

  void runStatsService() {
    if (store == null) return;

    String? lastState;
    Stream.periodic(Duration(seconds: 10)).listen((event) async {
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

        final resHash = await rust.hashBlake3(input: res.bodyBytes);

        if (!areBytesEqual(hash.hashBytes, resHash)) {
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

  void addDownloadUri(Multihash hash, NodeID nodeId, String url, int ttl) {
    final val = objectsBox.get(hash.toBase64Url()) ?? {};
    val[nodeId.toBase58()] = {
      'uri': url,
      'ttl': ttl,
    };
    objectsBox.put(hash.toBase64Url(), val);
  }

  Future<AuthResponse> checkAuth(HttpRequest req, String scope) async {
    if (accounts == null) {
      // TODO Return "default user"
      return AuthResponse(user: null, denied: false, error: null);
    }
    return accounts!.checkAuth(req, scope);
  }

  Map<NodeID, Uri> getDownloadUrisFromDB(Multihash hash) {
    final uris = <NodeID, Uri>{};
    final val = objectsBox.get(hash.toBase64Url()) ?? {};
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final e in val.entries) {
      if (e.value['ttl'] < ts) {
      } else {
        uris[NodeID.decode(e.key)] = Uri.parse(
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

  Future<CID> uploadMemoryDirectory(
    Map<String, Uint8List> paths, {
    String? dirname,
    List<String>? tryFiles,
    Map<int, String>? errorPages,
  }) async {
    final p = Packer();

    p.packInt(metadataMagicByte);
    p.packInt(metadataTypeWebApp);

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
      p.packBinary(cids[path]!.toBytes());
      p.packString(
        lookupMimeType(
          path.split('/').last,
          headerBytes: bytes.sublist(0, min(32, bytes.length)),
        ),
      );
    }

    p.packMapLength(0);

    final cid = await uploadRawFile(p.takeBytes());

    return CID(cidTypeMetadataWebApp, cid.hash);
  }

  Future<void> deleteFile(CID cid) async {
    if (cid.type == cidTypeRaw) {
      await deleteHash(cid.hash);
    } else {
      throw 'Can\'t delete this type of CID';
    }
  }

  Future<void> deleteHash(Multihash hash) async {
    objectsBox.delete(hash.toBase64Url());
    await store?.delete(hash);
  }

  Future<void> pinFile(CID cid, {User? user}) async {
    if (cid.type == cidTypeRaw) {
      await pinHash(cid.hash, user: user);
    } else {
      throw 'Can\'t pin this type of CID';
    }
  }

  Future<void> pinHash(Multihash hash, {User? user}) async {
    if (await store!.contains(hash)) {
      if (user != null) {
        await accounts!.addObjectPinToUser(
          user: user,
          hash: hash,
          size: 0,
        );
      }
      return;
    }
    final bytes = await downloadBytesByHash(hash);
    await store!.put(hash, Stream.value(bytes));

    if (user != null) {
      await accounts!.addObjectPinToUser(
        user: user,
        hash: hash,
        size: bytes.length,
      );
    }
  }

  Future<Metadata> getMetadataByCID(CID cid) async {
    final hash = cid.hash;

    late final Metadata metadata;

    if (metadataCache.containsKey(hash)) {
      metadata = metadataCache[hash]!;
    } else {
      final bytes = await downloadBytesByHash(hash);

      if (cid.type == cidTypeMetadataMedia) {
        metadata = await deserializeMediaMetadata(bytes, crypto: crypto);
      } else if (cid.type == cidTypeMetadataWebApp) {
        metadata = deserializeWebAppMetadata(bytes);
      } else {
        throw 'Unsupported metadata format';
      }
      metadataCache[hash] = metadata;
    }
    return metadata;
  }

  Future<CID> uploadRawFile(Uint8List data) async {
    if (data.length > 32 * 1024 * 1024) {
      throw 'This API only supports a maximum size of 32 MiB';
    }

    final baoResult = await rust.hashBaoMemory(
      bytes: data,
    );

    final hash = Multihash(
      Uint8List.fromList(
        [mhashBlake3Default] + baoResult.hash,
      ),
    );

    await store!.put(
      hash,
      _uploadRawStream(
        Stream.value(data),
        baoResult,
        data.length,
      ),
    );

    return CID(
      cidTypeRaw,
      hash,
      size: data.length,
    );
  }

  Future<CID> uploadLocalFile(File file) async {
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

    final size = file.lengthSync();

    final baoResult = await rust.hashBaoFile(
      path: file.path,
    );
    final hash = Multihash(
      Uint8List.fromList(
        [mhashBlake3Default] + baoResult.hash,
      ),
    );

    await store!.put(
      hash,
      _uploadRawFile(file, baoResult, size),
    );

    return CID(
      cidTypeRaw,
      hash,
      size: size,
    );
  }

  Stream<Uint8List> _uploadRawFile(
    File file,
    BaoResult baoResult,
    int size,
  ) {
    return _uploadRawStream(
      file.openRead().map((event) => Uint8List.fromList(event)),
      baoResult,
      size,
    );
  }

  Stream<Uint8List> _uploadRawStream(
    Stream<Uint8List> stream,
    BaoResult baoResult,
    int size,
  ) async* {
    yield* stream;

    if (size <= defaultChunkSize) {
      return;
    }

    final meta = Uint8List(16);
    meta[15] = 0x8d;
    meta[14] = 0x1c;
    meta[13] = 0x4b;
    meta[12] = 0x7a;
    meta[11] = 3; // type (bao)
    meta[10] = 8; // bao depth

    _copyTo(meta, 0, encodeEndian(baoResult.outboard.length, 8));

    yield Uint8List.fromList(baoResult.outboard + meta);
  }

  void _copyTo(Uint8List list, int offset, Uint8List input) {
    for (int i = 0; i < input.length; i++) {
      list[offset + i] = input[i];
    }
  }
}
