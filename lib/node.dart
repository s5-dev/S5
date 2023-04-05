import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart';
import 'package:messagepack/messagepack.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:tint/tint.dart';

import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';

import 'accounts/user.dart';
import 'constants.dart';
import 'db/hive_key_value_db.dart';
import 'download/uri_provider.dart';
import 'http_api/http_api.dart';
import 'http_api/serve_chunked_file.dart';
import 'logger/base.dart';
import 'rust/bridge_definitions.dart';
import 'service/accounts.dart';
import 'service/cache_cleaner.dart';
import 'service/p2p.dart';
import 'service/registry.dart';
import 'store/base.dart';
import 'store/create.dart';
import 'store/merge.dart';

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

  late final KeyValueDB objectsBox;

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

    objectsBox = HiveKeyValueDB(await Hive.openBox('s5-object-cache'));

    p2p = P2PService(this);

    p2p.nodeKeyPair = await crypto.newKeyPairEd25519(
      seed: base64UrlNoPaddingDecode(
        (config['keypair']['seed'] as String).replaceAll('=', ''),
      ),
    );

    await p2p.init();

    logger.info('${'NODE ID'.bold()}: ${p2p.localNodeId.toString().green()}');

    logger.info('');

    registry = RegistryService(this);
    await registry.init();

    cachePath = config['cache']['path']!;

    final cacheCleaner = CacheCleaner(Directory(cachePath), logger);

    cacheCleaner.start();

    exposeStore = config['store']?['expose'] ?? true;

    final stores = createStoresFromConfig(
      config,
      httpClient: httpClient,
    );

    if (stores.isEmpty) {
      exposeStore = false;
    } else {
      if (stores.length > 1) {
        final Map storeConfig = config['store'];
        if (storeConfig['merge'] == true) {
          store = MergedObjectStore(
            stores,
            allowedUploadSizes: storeConfig['allowedUploadSizes'],
          );
          logger.info('[${store.runtimeType}] init...');
          await store!.init();
          logger.info('[${store.runtimeType}] ready.');
        } else {
          throw 'More than one store configured (${stores.keys.toList().join(', ')}), enable the merge store if you actually want to use multiple at once';
        }
      } else {
        store = stores.values.first;
        logger.info('[${store.runtimeType}] init...');
        await store!.init();
        logger.info('[${store.runtimeType}] ready.');
      }
    }

    await p2p.start();

    final httpAPIServer = HttpAPIServer(this);

    final accountsConfig = config['accounts'];
    if (accountsConfig?['enabled'] == true) {
      accounts = AccountsService(
        accountsConfig,
        logger: logger,
        crypto: crypto,
      );
      await accounts!.init(httpAPIServer.app);
    }

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

    final dlUriProvider = StorageLocationProvider(this, hash, [
      storageLocationTypeFull,
      storageLocationTypeFile,
    ]);

    dlUriProvider.start();

    while (true) {
      final dlUri = await dlUriProvider.next();

      logger.verbose('[try] ${dlUri.location.bytesUrl}');

      try {
        final res = await client
            .get(Uri.parse(dlUri.location.bytesUrl))
            .timeout(Duration(seconds: 30)); // TODO Adjust timeout

        if (hash.functionType == cidTypeBridge) {
          if (res.statusCode != 200) {
            throw 'HTTP ${res.statusCode}: ${res.body} for ${dlUri.location.bytesUrl}';
          }
          // TODO Have list of trusted Node IDs here, already filter them BEFORE EVEN DOWNLOADING
        } else {
          final resHash = await rust.hashBlake3(input: res.bodyBytes);

          if (!areBytesEqual(hash.hashBytes, resHash)) {
            throw 'Integrity verification failed';
          }
          dlUriProvider.upvote(dlUri);
        }

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

/*   void runObjectGarbageCollector() {
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
  } */

  Future<String> resolveName(String name) async {
    logger.verbose('[dns] resolveName $name');

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
        'dns0.eu',
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

  Map<int, Map<NodeID, Map<int, dynamic>>> readStorageLocationsFromDB(
    Multihash hash,
  ) {
    final Map<int, Map<NodeID, Map<int, dynamic>>> map = {};
    final bytes = objectsBox.get(hash.fullBytes);
    if (bytes == null) {
      return map;
    }
    final unpacker = Unpacker(bytes);
    final mapLength = unpacker.unpackMapLength();
    for (int i = 0; i < mapLength; i++) {
      final type = unpacker.unpackInt();
      map[type!] = {};
      final mapLength = unpacker.unpackMapLength();
      for (int j = 0; j < mapLength; j++) {
        final nodeId = unpacker.unpackBinary();
        map[type]![NodeID(nodeId)] = unpacker.unpackMap().cast<int, dynamic>();
      }
    }
    return map;
  }

  void addStorageLocation(
    Multihash hash,
    NodeID nodeId,
    StorageLocation location, {
    Uint8List? message,
  }) async {
    final map = readStorageLocationsFromDB(hash);

    map[location.type] ??= {};

    map[location.type]![nodeId] = {
      1: location.parts,
      // 2: location.binaryParts,
      3: location.expiry,
      4: message,
    };

    objectsBox.set(
      hash.fullBytes,
      (Packer()..pack(map)).takeBytes(),
    );
  }

  Future<AuthResponse> checkAuth(HttpRequest req, String scope) async {
    if (accounts == null) {
      // TODO Return "default user"
      return AuthResponse(user: null, denied: false, error: null);
    }
    return accounts!.checkAuth(req, scope);
  }

  Map<NodeID, StorageLocation> getCachedStorageLocations(
    Multihash hash,
    List<int> types,
  ) {
    final locations = <NodeID, StorageLocation>{};

    final map = readStorageLocationsFromDB(hash);
    if (map.isEmpty) {
      return {};
    }

    final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();

    for (final type in types) {
      if (!map.containsKey(type)) continue;
      for (final e in map[type]!.entries) {
        if (e.value[3] < ts) {
        } else {
          locations[e.key] = StorageLocation(
            type,
            e.value[1].cast<String>(),
            e.value[3],
          )..providerMessage = e.value[4];
        }
      }
    }
    return locations;
  }

  Future<void> fetchHashLocally(Multihash hash, List<int> types) async {
    if (store != null) {
      if (await store!.canProvide(hash, types)) {
        final location = await store!.provide(hash, types);

        addStorageLocation(
          hash,
          p2p.localNodeId,
          location,
          message: await p2p.prepareProvideMessage(hash, location),
        );
      }
    }
  }

  Future<CID> uploadMemoryDirectory(
    Map<String, Uint8List> paths, {
    String? name,
    List<String>? tryFiles,
    Map<int, String>? errorPages,
  }) async {
    final p = Packer();

    p.packInt(metadataMagicByte);
    p.packInt(metadataTypeWebApp);

    p.packListLength(5);

    p.packString(name);

    p.packListLength(tryFiles?.length ?? 0);

    for (final path in tryFiles ?? []) {
      p.packString(path);
    }

    p.packMapLength(errorPages?.length ?? 0);

    for (final e in errorPages?.entries.toList() ?? <MapEntry>[]) {
      p.packInt(e.key);
      p.packString(e.value);
    }

    p.packListLength(paths.length);

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
      p.packListLength(3);
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
    objectsBox.delete(hash.fullBytes);
    await store?.delete(hash);
  }

  Future<void> pinCID(CID cid, {User? user}) async {
    if (await store!.contains(cid.hash)) {
      if (user != null) {
        await accounts!.addObjectPinToUser(
          user: user,
          hash: cid.hash,
          size: 0,
        );
      }
      return;
    }

    final cacheFile = File(
      join(
        cachePath,
        'download',
        Multihash(crypto.generateRandomBytes(32)).toBase32(),
        'file',
      ),
    );
    cacheFile.createSync(recursive: true);

    await downloadFileByHash(
      hash: cid.hash,
      outputFile: cacheFile,
      size: cid.size,
    );

    final newCID = await uploadLocalFile(
      cacheFile,
    );

    if (cid.hash != newCID.hash) {
      throw 'Hash mismatch (${cid.hash} != ${newCID.hash})';
    }

    if (user != null) {
      await accounts!.addObjectPinToUser(
        user: user,
        hash: cid.hash,
        size: cacheFile.lengthSync(),
      );
    }
    await cacheFile.delete();
  }

  Future<void> downloadFileByHash({
    required Multihash hash,
    required File outputFile,
    int? size,
    Function? onProgress,
    CancellationToken? cancelToken,
  }) async {
    final sink = outputFile.openWrite();

    final dlUriProvider = StorageLocationProvider(this, hash, [
      storageLocationTypeFull,
      storageLocationTypeFile,
    ]);

    dlUriProvider.start();

    int progress = 0;

    try {
      final dlUri = await dlUriProvider.next();

      final request = Request('GET', Uri.parse(dlUri.location.bytesUrl));

      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }

      final completer = Completer();

      final sub = response.stream.listen(
        (chunk) {
          progress += chunk.length;
          if (onProgress != null) {
            onProgress(size == null ? null : progress / size);
          }

          sink.add(chunk);
        },
        onError: (e) {
          completer.completeError(e);
        },
        onDone: () {
          completer.complete();
        },
      );

      if (cancelToken != null) {
        CancellableCompleter(cancelToken, onCancel: () {
          sub.cancel();
          completer.complete();
        });
      }

      await completer.future;

      await sink.close();

      final b3hash = await rust.hashBlake3File(path: outputFile.path);
      final localFileHash =
          Multihash(Uint8List.fromList([mhashBlake3Default] + b3hash));

      if (hash != localFileHash) {
        throw 'Hash mismatch';
      }

      if (cancelToken?.isCancelled ?? false) {
        await sink.close();
        await outputFile.delete();

        throw CancelledException();
      }
    } catch (e, st) {
      rethrow;
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
      } else if (cid.type == cidTypeBridge) {
        metadata = await deserializeMediaMetadata(bytes, crypto: crypto);
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

    await store!.put(hash, Stream.value(data), data.length);

    if (data.length > defaultChunkSize) {
      await store!.putBaoOutboardBytes(hash, baoResult.outboard);
    }

    return CID(
      cidTypeRaw,
      hash,
      size: data.length,
    );
  }

  Future<CID> uploadLocalFile(File file, {bool withOutboard = true}) async {
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
      file.openRead().map((event) => Uint8List.fromList(event)),
      size,
    );
    if (size > defaultChunkSize && withOutboard) {
      await store!.putBaoOutboardBytes(hash, baoResult.outboard);
    }

    return CID(
      cidTypeRaw,
      hash,
      size: size,
    );
  }

  void _copyTo(Uint8List list, int offset, Uint8List input) {
    for (int i = 0; i < input.length; i++) {
      list[offset + i] = input[i];
    }
  }
}
