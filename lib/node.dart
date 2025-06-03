import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:s5_msgpack/s5_msgpack.dart';

import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/node.dart';
import 'package:lib5/util.dart';
import 'package:s5_server/rust/api.dart';

import 'accounts/account.dart';
import 'constants.dart';
import 'db/hive_key_value_db.dart';
import 'http_api/http_api.dart';
import 'service/accounts.dart';
import 'service/cache_cleaner.dart';
import 'service/p2p.dart';
import 'store/create.dart';
import 'store/merge.dart';

class S5Node extends S5NodeBase {
  S5Node({
    required super.config,
    required super.logger,
    required super.crypto,
  }) {
    maxMemoryUploadSizeMB =
        config['http']?['api']?['maxMemoryUploadSizeMB'] ?? 34;
  }

  late final String cachePath;

  final rawFileUploadPool = Pool(16);

  ObjectStore? store;
  late bool exposeStore;
  late final int maxMemoryUploadSizeMB;

  AccountsService? accounts;

  @override
  Future<void> start() async {
    if (config['database']?['path'] != null) {
      Hive.init(config['database']['path']);
    }

    await init(
      blobDB: HiveKeyValueDB(
        await Hive.openBox('s5-object-cache'),
      ),
      registryDB: HiveKeyValueDB(await Hive.openBox('s5-registry-db')),
      streamDB: HiveKeyValueDB(await Hive.openBox('s5-stream-db')),
      nodesDB: HiveKeyValueDB(await Hive.openBox('s5-nodes')),
      p2pService: NativeP2PService(this),
    );

    cachePath = config['cache']['path']!;

    final cacheCleaner = CacheCleaner(
      Directory(cachePath),
      logger,
      maxCacheSizeInGB: config['cache']['maxSizeInGB'] ?? 4,
    );

    cacheCleaner.start();

    exposeStore = config['store']?['expose'] ?? true;

    final stores = createStoresFromConfig(
      config,
      httpClient: httpClient,
      node: this,
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
    } else {
      if (config['http']?['api']?['domain'] != null) {
        logger.warn(
          'It looks like you have a public domain, but the accounts system is not enabled. This means that anyone could upload files to your node, so enable the accounts system if you don\'t want that.',
        );
      }
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
        cid.hash.fullBytes,
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

    int retryCount = 0;
    while (true) {
      final dlUri = await dlUriProvider.next();

      logger.verbose('[try] ${dlUri.location.bytesUrl}');

      try {
        final res = await httpClient
            .get(Uri.parse(dlUri.location.bytesUrl))
            .timeout(Duration(seconds: 30)); // TODO Adjust timeout

        if (hash.type == cidTypeBridge) {
          if (res.statusCode != 200) {
            throw 'HTTP ${res.statusCode}: ${res.body} for ${dlUri.location.bytesUrl}';
          }
          // TODO Have list of trusted Node IDs here, already filter them BEFORE EVEN DOWNLOADING
        } else {
          final resHash = await hashBlake3(input: res.bodyBytes);

          if (!areBytesEqual(hash.value, resHash)) {
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
      retryCount++;
      if (retryCount > 32) {
        throw 'Too many retries';
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
    final res = await httpClient.get(
      Uri.https(
        'cloudflare-dns.com',
        '/dns-query',
        {
          'name': name,
          'type': 'TXT',
        },
      ),
      headers: {
        'accept': 'application/dns-json',
      },
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

  Future<AuthResponse> checkAuth(
    HttpRequest req,
    String scope, {
    bool restricted = false,
  }) async {
    if (accounts == null) {
      // TODO Return "default account"
      return AuthResponse(account: null, denied: false, error: null);
    }
    final res = await accounts!.checkAuth(req, scope);
    if (restricted) {
      if (res.account?.isRestricted ?? false) {
        return AuthResponse(
          account: res.account,
          denied: true,
          error: 'This account is restricted',
        );
      }
    }
    return res;
  }

  @override
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

  Future<void> pinCID(CID cid, {Account? account}) async {
    if (await store!.contains(cid.hash)) {
      if (account != null) {
        await accounts!.addObjectPinToAccount(
          account: account,
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
        Multihash(crypto.generateSecureRandomBytes(32)).toBase32(),
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

    if (account != null) {
      await accounts!.addObjectPinToAccount(
        account: account,
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

      final response = await httpClient.send(request);

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

      if (cancelToken?.isCancelled ?? false) {
        await outputFile.delete();
        throw CancelledException();
      }

      final b3hash = await hashBlake3File(path: outputFile.path);
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
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<CID> uploadRawFile(Uint8List data) async {
    if (data.length > maxMemoryUploadSizeMB * 1000 * 1000) {
      throw 'This API only supports a maximum size of $maxMemoryUploadSizeMB MB';
    }

    final baoResult = await hashBaoMemory(
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

  Future<CID> uploadLocalFile(
    File file, {
    bool withOutboard = true,
    Function? onProgress,
    CancellationToken? cancelToken,
  }) async {
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

    final baoResult = await hashBaoFile(
      path: file.path,
    );
    final hash = Multihash(
      Uint8List.fromList(
        [mhashBlake3Default] + baoResult.hash,
      ),
    );

    int pushedByteCount = 0;

    if (onProgress != null) {
      Stream.periodic(Duration(milliseconds: 100)).listen((_) {
        onProgress(pushedByteCount / size);
      });
    }

    await store!.put(
      hash,
      onProgress == null
          ? file.openRead().map((event) => Uint8List.fromList(event))
          : file.openRead().map((event) {
              if (cancelToken?.isCancelled ?? false) throw 'Upload cancelled';
              pushedByteCount += event.length;
              return Uint8List.fromList(event);
            }),
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

  // TODO Move this to lib5
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

    tryFiles?.sort();

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

    final pathKeys = paths.keys.toList();

    pathKeys.sort();

    for (final path in pathKeys) {
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

    return CID(cidTypeMetadataDirectory, cid.hash);
  }

  void _copyTo(Uint8List list, int offset, Uint8List input) {
    for (int i = 0; i < input.length; i++) {
      list[offset + i] = input[i];
    }
  }
}
