import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
// ignore: implementation_imports
import 'package:alfred/src/type_handlers/websocket_type_handler.dart';
import 'package:base_codecs/base_codecs.dart';
import 'package:http/http.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:messagepack/messagepack.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart';
import 'package:s5_server/accounts/account.dart';

import 'package:s5_server/constants.dart';
import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/http_api/admin.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/service/accounts.dart';
import 'package:s5_server/util/uid.dart';
import 'package:s5_server/util/multipart.dart';
import 'serve_chunked_file.dart';

class HttpAPIServer {
  final S5Node node;

  HttpAPIServer(this.node) {
    adminAPI = AdminAPI(node);
  }

  final app = Alfred();

  late final AdminAPI adminAPI;

  Future<void> start(String cachePath) async {
    if (node.config['http']?['api']?['admin']?['enabled'] != false) {
      adminAPI.init(app);
    }

    app.get(
      '/',
      (req, res) => 'S5 Node is running! :) v$nodeVersion',
    );

    // TODO
    app.get('/favicon.ico', (req, res) => '');

    app.get(
      '/s5/version',
      (req, res) => {
        'node': nodeVersion,
        // 'api':
        // 'protocol':
      },
    );
    app.get('/s5/account/set-auth-cookie/:token', (req, res) {
      final token = req.params['token'];
      // TODO Ensure token is valid

      node.accounts!.setSetCookieHeader(
        res,
        token,
        req.requestedUri.host,
      );

      res.redirect(
        Uri.parse('/s5/account/stats'),
        status: 307,
      );
    });

    app.head('/s5/upload/directory', (req, res) => '');

    app.post('/s5/upload/directory', (req, res) async {
      final auth = await node.checkAuth(req, 's5/upload/directory');
      if (auth.denied) return res.unauthorized(auth);

      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }
      if (req.isMultipartForm) {
        final files = <String, Uint8List>{
          await for (final formData in req.multipartFormData)
            formData.name: await formData.part.readBytes(),
        };

        final queryParams = req.uri.queryParameters;

        final cid = await node.uploadMemoryDirectory(
          files,
          tryFiles: json
              .decode(
                queryParams['tryfiles'] ?? '[]',
              )
              .cast<String>(),
          errorPages: json
              .decode(
                queryParams['errorpages'] ?? '{}',
              )
              .map((key, value) => MapEntry(int.parse(key), value))
              .cast<int, String>(),
          name: queryParams['name'],
        );

        return {
          'cid': cid.toBase58(),
        };
      } else {
        throw 'Not a multipart directory upload';
      }
    });

    app.head('/s5/upload', (req, res) => '');

    app.post('/s5/upload', (req, res) async {
      final auth = await node.checkAuth(req, 's5/upload');
      if (auth.denied) return res.unauthorized(auth);

      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }

      Uint8List bytes;

      if (req.headers.contentType?.mimeType == 'multipart/form-data') {
        final body = (await req.body as Map);

        final HttpBodyFileUpload file = body['file'];
        bytes = Uint8List.fromList(
          file.content is String
              ? (file.content as String).codeUnits
              : file.content,
        );
      } else {
        final byteList = <int>[];

        await for (final chunk in req) {
          byteList.addAll(chunk);
        }

        bytes = Uint8List.fromList(byteList);
      }

      final cid = await node.uploadRawFile(bytes);

      if (auth.account != null) {
        await node.accounts!.addObjectPinToAccount(
          account: auth.account!,
          hash: cid.hash,
          size: bytes.length,
        );
      }

      return {
        'cid': cid.toBase58(),
      };
    });

/*     app.post('/s5/upload', (req, res) async {
      final auth = await node.checkAuth(req, 's5/upload');
      if (auth.denied) return res.unauthorized(auth);

      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }

      final body = (await req.body as Map);

      final HttpBodyFileUpload file = body['file'];

      final cacheFile = File(
        join(cachePath, 'upload', generateUID(node.crypto), file.filename),
      );
      cacheFile.parent.createSync(recursive: true);
      cacheFile.writeAsBytesSync(
        Uint8List.fromList(file.content is String
            ? (file.content as String).codeUnits
            : file.content),
      );

      final cid = await node.uploadLocalFile(cacheFile);

      await cacheFile.delete();
      cacheFile.parent.delete();

      return {
        'cid': cid.toBase58(),
      };
    }); */

    app.head('/s5/delete/:cid', (req, res) => '');

    app.delete('/s5/delete/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/delete');
      if (auth.denied) return res.unauthorized(auth);

      if (node.config['http']?['api']?['delete']?['enabled'] != true) {
        res.statusCode = HttpStatus.unauthorized;
        return 'Endpoint disabled in config.toml';
      }
      final cid = CID.decode(req.params['cid']);

      if (auth.account != null) {
        final shouldDelete = await node.accounts!.deleteObjectPin(
          account: auth.account!,
          hash: cid.hash,
        );
        if (shouldDelete) {
          await node.deleteFile(cid);
        }
      } else {
        await node.deleteFile(cid);
      }
    });

    app.head('/s5/pin/:cid', (req, res) => '');

    // TODO Add ?routingHints=
    app.post('/s5/pin/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/pin');
      if (auth.denied) return res.unauthorized(auth);

      final cid = CID.decode(req.params['cid']);

      await node.pinCID(
        cid,
        account: auth.account,
      );
    });

/*     app.get(
      '/s5/debug/nodes',
      (req, res) async {
        final auth = await node.checkAuth(req, 's5/debug/nodes');
        if (auth.denied) return res.unauthorized(auth);

        return node.p2p.nodesBox.toMap().cast<String, dynamic>();
      },
    );

    app.get(
      '/s5/debug/objects',
      (req, res) async {
        final auth = await node.checkAuth(req, 's5/debug/objects');
        if (auth.denied) return res.unauthorized(auth);

        return node.objectsBox.toMap().cast<String, dynamic>();
      },
    ); */

    // TODO Persist upload sessions to cache (disk)
    final tusUploadSessions = <String, TusUploadSession>{};

    app.head('/s5/upload/tus/:id', (req, res) async {
      final uploadId = req.params['id'] as String;
      final tus = tusUploadSessions[uploadId];
      if (tus == null) {
        res.statusCode = 404;
        return;
      }
      res.headers.set('Tus-Resumable', '1.0.0');
      res.headers.set('Upload-Offset', tus.offset.toString());
      res.headers.set('Upload-Length', tus.totalLength.toString());
      res.headers.set('Content-Length', tus.totalLength.toString());
      res.headers.set('Cache-Control', 'no-store');
      // TODO Upload-Metadata

      res.close();
    });

    app.patch('/s5/upload/tus/:id', (req, res) async {
      final uploadId = req.params['id'] as String;
      final tus = tusUploadSessions[uploadId];
      if (tus == null) {
        res.statusCode = 404;
        return;
      }
      final uploadOffset = int.parse(req.headers.value('upload-offset')!);

      if (uploadOffset != tus.offset) {
        throw 'Invalid offset';
      }

      final sink = tus.cacheFile.openWrite(mode: FileMode.writeOnlyAppend);

      await sink.addStream(req);

      await sink.close();

      res.headers.set('Tus-Resumable', '1.0.0');

      if (tus.offset == tus.totalLength) {
        final uploadRes = await node.uploadLocalFile(tus.cacheFile);

        if (uploadRes.hash != tus.expectedHash) {
          await node.store!.delete(uploadRes.hash);
          tusUploadSessions.remove(uploadId);
          await tus.cacheFile.delete();
          throw 'Invalid hash found';
        }

        if (tus.account != null) {
          await node.accounts!.addObjectPinToAccount(
            account: tus.account!,
            hash: tus.expectedHash,
            size: tus.totalLength,
          );
        }

        await tus.cacheFile.delete();

        res.statusCode = 204;
        res.headers.set('Upload-Offset', tus.totalLength);

        Future.delayed(Duration(minutes: 10)).then((value) {
          tusUploadSessions.remove(uploadId);
        });
      }
    });

    app.post('/s5/upload/tus', (req, res) async {
      final auth = await node.checkAuth(req, 's5/upload/tus');
      if (auth.denied) return res.unauthorized(auth);

      final uploadLength = int.parse(req.headers.value('upload-length')!);

      final String uploadMetadata = req.headers.value('upload-metadata')!;

      final hashStr = uploadMetadata.split(',').map((element) {
        return element.split(' ');
      }).firstWhere((element) => element[0] == 'hash')[1];

      final uploadId = base58BitcoinEncode(
        node.crypto.generateRandomBytes(32),
      );

      final mhash =
          Multihash.fromBase64Url(utf8.decode(base64.decode(hashStr)));

      if (await node.store!.contains(mhash)) {
        // TODO If accounts system is enabled, pin to account
        res.statusCode = HttpStatus.conflict;

        throw 'Raw file with CID ${CID(cidTypeRaw, mhash, size: uploadLength)} has already been uploaded to this node';
      }

      final cacheFile = File(
        join(cachePath, 'tus_upload', uploadId, 'file'),
      );
      cacheFile.createSync(recursive: true);

      tusUploadSessions[uploadId] = TusUploadSession(
        totalLength: uploadLength,
        expectedHash: mhash,
        cacheFile: cacheFile,
        account: auth.account,
      );

      final location =
          req.requestedUri.replace(path: '/s5/upload/tus/$uploadId');

      res.headers.set('Tus-Resumable', '1.0.0');
      res.headers.set('location', location);
      res.statusCode = 201;
      res.close();
    });

    app.post('/s5/import/http', (req, res) async {
      final auth = await node.checkAuth(req, 's5/import/http');
      if (auth.denied) return res.unauthorized(auth);

      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }

      final url = req.uri.queryParameters['url']!;

      final cacheFile = File(
        join(
          cachePath,
          'uploading-cache',
          generateUID(node.crypto),
        ),
      );
      cacheFile.createSync(recursive: true);

      final request = Request('GET', Uri.parse(url));
      final headers = json.decode(req.uri.queryParameters['headers'] ?? '{}');
      headers['accept-language'] = 'en-us,en;q=0.5';

      headers['accept-encoding'] = '*';

      for (final h in headers.entries) {
        request.headers[h.key] = h.value;
      }

      final response = await httpClient.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw 'HTTP ${response.statusCode}';
      }

      final sink = cacheFile.openWrite();

      await sink.addStream(response.stream);

      await sink.close();

      final cid = await node.uploadLocalFile(
        cacheFile,
      );

      if (auth.account != null) {
        await node.accounts!.addObjectPinToAccount(
          account: auth.account!,
          hash: cid.hash,
          size: cacheFile.lengthSync(),
        );
      }

      await cacheFile.delete();

      return {
        'cid': cid.toBase58(),
      };
    });

/*     app.post('/s5/import/local_file', (req, res) async {
      final auth = await node.checkAuth(req, 's5/import/local_file');
      if (auth.denied) return res.unauthorized(auth);

      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }

      final file = File(req.uri.queryParameters['path']!);

      final cid = await node.uploadLocalFile(
        file,
      );

      if (auth.account != null) {
        await node.accounts!.addObjectPinToAccount(
          account: auth.account!,
          hash: cid.hash,
          size: file.lengthSync(),
        );
      }

      return {
        'cid': cid.toBase58(),
      };
    }); */

    // TODO Support HEAD requests

    app.get('/s5/blob/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/blob/redirect');
      if (auth.denied) return res.unauthorized(auth);

      final cidStr = req.params['cid'].split('.').first;

      final cid = CID.decode(cidStr);

      final dlUriProvider = StorageLocationProvider(node, cid.hash, [
        storageLocationTypeFull,
        storageLocationTypeFile,
        storageLocationTypeBridge,
      ]);

      dlUriProvider.start();

      await res.redirect(
        Uri.parse((await dlUriProvider.next()).location.bytesUrl),
        status: HttpStatus.temporaryRedirect,
      );
      return;
    });

    app.get('/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/download');
      if (auth.denied) return res.unauthorized(auth);

      final cidStr = req.params['cid'].split('.').first;

      final cid = CID.decode(cidStr);

      if (cid.type == cidTypeMetadataWebApp || cid.type == cidTypeResolver) {
        final base32cid = cid.toBase32();
        final requestedUri = req.requestedUri;
        await res.redirect(
          requestedUri.replace(
            host: '$base32cid.${requestedUri.host}',
            path: '',
          ),
          status: HttpStatus.temporaryRedirect,
        );
        return;
      }

      if (cid.type == cidTypeMetadataMedia) {
        await res.redirect(
          req.requestedUri.replace(pathSegments: [
            's5',
            'metadata',
            cid.toBase58(),
          ]),
          status: HttpStatus.temporaryRedirect,
        );
        return;
      }

      final hash = cid.hash;

      final filename =
          req.uri.queryParameters['filename'] ?? req.uri.pathSegments.last;

      var mediaType = lookupMimeType(
            filename,
          ) ??
          'application/octet-stream';

      if (filename.endsWith('mpd')) {
        mediaType = 'application/dash+xml';
      }

      if (mediaType == 'text/plain') {
        mediaType += '; charset=utf-8';
      }

      res.headers.set(
        'content-type',
        mediaType,
      );

      res.headers.set(
        'content-disposition',
        'inline; filename="$filename"',
      );

      res.headers.set(
        'etag',
        '"${hash.toBase64Url()}"',
      );
      res.headers.set(
        'accept-ranges',
        'bytes',
      );

      setUnlimitedCacheHeader(res);

      if (cid.size == null || cid.size! <= defaultChunkSize) {
        res.add(await node.downloadBytesByHash(hash));
        await res.close();
        return;
      }

      // TODO date header

      await handleChunkedFile(
        req,
        res,
        cid.hash,
        cid.size!,
        cachePath: join(cachePath, 'streamed_files'),
        logger: node.logger,
        node: node,
      );
    });

    app.get('/s5/metadata/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/metadata');
      if (auth.denied) return res.unauthorized(auth);

      final cid = CID.decode(req.params['cid']);

      if (cid.type == cidTypeRaw) {
        throw 'Raw CIDs do not have metadata';
      } else if (cid.type == cidTypeResolver) {
        // TODO Support resolver CIDs
        throw 'This endpoint does not support resolver CIDs yet';
      }

      final metadata = await node.getMetadataByCID(cid);

      if (cid.type != cidTypeBridge) {
        setUnlimitedCacheHeader(res);
      } else {
        res.headers.set(
          'Cache-Control',
          'public, max-age=60',
        );
      }

      return metadata.toJson();
    });

    app.get('/s5/download/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/download');
      if (auth.denied) return res.unauthorized(auth);

      final cid = CID.decode(req.params['cid']);
      if (cid.type != cidTypeRaw) {
        throw 'This is not a raw CID';
      }
      final hash = cid.hash;

      res.headers.set(
        'content-type',
        'application/octet-stream',
      );

      res.headers.set(
        'etag',
        '"${hash.toBase64Url()}"',
      );

      final bytes = await node.downloadBytesByHash(hash);

      res.headers.set(
        'content-length',
        bytes.length,
      );

      setUnlimitedCacheHeader(res);

      res.add(bytes);
      res.close();
    });

    app.get('/s5/debug/storage_locations/:hash', (req, res) async {
      final auth = await node.checkAuth(req, 's5/debug/storage_locations');
      if (auth.denied) return res.unauthorized(auth);

      final hash = Multihash.fromBase64Url(req.params['hash']);

      final types = req.uri.queryParameters['types']
              ?.split(',')
              .map((e) => int.parse(e))
              .toList() ??
          [
            storageLocationTypeBridge,
            storageLocationTypeFull,
            storageLocationTypeFile,
            storageLocationTypeArchive,
          ];

      final dlUriProvider = StorageLocationProvider(
        node,
        hash,
        types,
      );

      dlUriProvider.start();
      await dlUriProvider.next();

      final map = node.getCachedStorageLocations(hash, types);

      final availableNodes = map.keys.toList();
      node.p2p.sortNodesByScore(availableNodes);

      final locations = [];

      for (final nodeId in availableNodes) {
        final entry = map[nodeId]!;
        locations.add({
          'type': entry.type,
          'parts': entry.parts,
          'expiry': entry.expiry,
          'nodeId': nodeId.toBase58(),
          'score': node.p2p.getNodeScore(nodeId),
        });
      }

      return {
        'locations': locations,
      };
    });
    app.get('/s5/debug/download_urls/:cid', (req, res) async {
      final auth = await node.checkAuth(req, 's5/debug/download_urls');
      if (auth.denied) return res.unauthorized(auth);

      final cid = CID.decode(req.params['cid']);
      final hash = cid.hash;

      final dlUriProvider = StorageLocationProvider(node, hash, [
        storageLocationTypeFull,
        storageLocationTypeFile,
        storageLocationTypeBridge,
      ]);
      dlUriProvider.start();
      await dlUriProvider.next();

      final map = node.getCachedStorageLocations(hash, [
        storageLocationTypeFull,
      ]);

      final availableNodes = map.keys.toList();
      node.p2p.sortNodesByScore(availableNodes);

      final lines = <String>[];

      for (final nodeId in availableNodes) {
        lines.add(map[nodeId]!.bytesUrl);
      }
      res.add(utf8.encode(lines.join('\n')));
      res.close();
    });

    app.get(
      '/s5/p2p/nodes',
      (req, res) {
        return {
          'nodes': [
            {
              'id': node.p2p.localNodeId.toBase58(),
              'uris':
                  node.p2p.selfConnectionUris.map((e) => e.toString()).toList(),
            }
          ]
        };
      },
    );

    app.get('/s5/registry', (req, res) async {
      final auth = await node.checkAuth(req, 's5/registry/read');
      if (auth.denied) return res.unauthorized(auth);

      final queryParams = req.uri.queryParameters;

      final pk = base64UrlNoPaddingDecode(queryParams['pk']!);

      final entry = await node.registry.get(pk);
      if (entry == null) {
        res.statusCode = 404;
        return '';
      }
      final response = <String, dynamic>{
        'pk': base64UrlNoPaddingEncode(entry.pk),
        'revision': entry.revision,
        'data': base64UrlNoPaddingEncode(entry.data),
        'signature': base64UrlNoPaddingEncode(entry.signature),
      };

      return response;
    });

    app.head('/s5/registry', (req, res) => '');

    app.post('/s5/registry', (req, res) async {
      final auth = await node.checkAuth(req, 's5/registry/write');
      if (auth.denied) return res.unauthorized(auth);

      final map = await req.bodyAsJsonMap;

      final pk = base64UrlNoPaddingDecode(map['pk']!);

      final int revision = map['revision']!;
      final bytes = base64UrlNoPaddingDecode(map['data']!);
      final signature = base64UrlNoPaddingDecode(map['signature']!);

      await node.registry.set(
        SignedRegistryEntry(
          pk: pk,
          revision: revision,
          data: bytes,
          signature: signature,
        ),
      );
      res.statusCode = 204;
    });

    app.get('/s5/registry/subscription', (req, res) async {
      final auth = await node.checkAuth(req, 's5/registry/subscription');
      if (auth.denied) return res.unauthorized(auth);

      return WebSocketSession(
        onOpen: (ws) {},
        onMessage: (webSocket, data) {
          final u = Unpacker(data);
          final method = u.unpackInt();
          if (method == 2) {
            final stream = node.registry.listen(
              u.unpackBinary(),
            );

            stream.map((sre) {
              return node.registry.serializeRegistryEntry(sre);
            }).listen((event) {
              webSocket.add(event);
            });
          }
        },
        onClose: (ws) {
          // TODO Clean up subscriptions
        },
      );
    });

    final authorization = node.config['http']?['api']?['authorization'];

    final expectedAuthorizationHeaders = <String>{};

    if (authorization != null) {
      if (authorization['bearer_tokens'] != null) {
        for (final t in authorization['bearer_tokens']) {
          expectedAuthorizationHeaders.add('Bearer $t');
        }
      }
    }

    final _server = await HttpServer.bind(
      node.config['http']?['api']?['bind'] ?? '127.0.0.1',
      node.config['http']?['api']?['port'] ?? 5050,
      shared: true,
      backlog: 0,
    );

    _server.idleTimeout = Duration(seconds: 1);

    _server.listen((HttpRequest request) async {
      try {
        final res = request.response;
        final uri = request.requestedUri;
        res.headers.set(
          'access-control-allow-origin',
          request.headers['origin'] ?? '*',
        );

        res.headers.set('access-control-max-age', '86400');

        final additionalHeaders = {
          'access-control-allow-methods':
              'GET, POST, HEAD, OPTIONS, PUT, PATCH, DELETE',
          'access-control-allow-headers':
              'User-Agent,X-Requested-With,If-Modified-Since,If-None-Match,Cache-Control,Content-Type,Range,X-HTTP-Method-Override,upload-offset,upload-metadata,upload-length,tus-version,tus-resumable,tus-extension,tus-max-size,upload-concat,location',
          'access-control-expose-headers':
              'Content-Length,Content-Range,ETag,Accept-Ranges,upload-offset,upload-metadata,upload-length,tus-version,tus-resumable,tus-extension,tus-max-size,upload-concat,location',
          'access-control-allow-credentials': 'true',
          'vary': 'origin',
        };
        for (final h in additionalHeaders.entries) {
          res.headers.set(h.key, h.value);
        }

        res.headers.removeAll('x-frame-options');
        res.headers.removeAll('x-xss-protection');

        // TODO Maybe cache HEAD requests too
        if (request.method == 'OPTIONS') {
          res.headers.set('Cache-Control', 'public, max-age=86400');

          res.statusCode = 204;
          res.close();
          return;
        }

        if (expectedAuthorizationHeaders.isNotEmpty) {
          final authHeader = request.headers.value('authorization');
          if (!expectedAuthorizationHeaders.contains(authHeader)) {
            res.statusCode = HttpStatus.unauthorized;
            res.write('Unauthorized');
            res.close();
            return;
          }
        }

        CID? cid;

        final parts = uri.host.split('.');

        final String? domain = node.config['http']?['api']?['domain'];

        if (domain != null) {
          if (uri.host == 'docs.$domain') {
            cid = CID.decode('zrjD7xwmgP8U6hquPUtSRcZP1J1LvksSwTq4CPZ2ck96FHu');
          } else if (!('.${uri.host}').endsWith('.$domain')) {
            final cidStr = await node.resolveName(uri.host);
            cid = CID.decode(cidStr);
          } else {
            // TODO Check .ns.
          }
        }

        if (cid == null) {
          try {
            cid = CID.decode(parts[0]);
          } catch (_) {}
        }

        if (cid != null) {
          final auth = await node.checkAuth(request, 's5/subdomain/load');
          if (auth.denied) return res.unauthorized(auth);

          if (cid.type == cidTypeRaw) {
            throw 'Raw files can\'t be served on a subdomain. Try loading this CID on the root domain';
          } else if (cid.type == cidTypeMetadataMedia) {
            throw 'Media files can\'t be served on a subdomain. Try loading this CID on the root domain';
          }

          // TODO res.headers.set('s5-portal-api', 'http://localhost:9999');

          if (cid.type == cidTypeResolver) {
            final res = await node.registry.get(
              cid.hash.fullBytes,
            );
            if (res == null) {
              throw 'Registry entry is empty';
            }
            cid = CID.fromBytes(res.data.sublist(1));
          }

          final metadata = await node.getMetadataByCID(cid) as WebAppMetadata;

          WebAppMetadataFileReference? servedFile;

          var path = request.uri.path;
          if (path.startsWith('/')) {
            path = path.substring(1);
          }
          if (path.endsWith('/')) {
            path = path.substring(0, path.length - 1);
          }

          if (metadata.paths.containsKey(path)) {
            servedFile = metadata.paths[path]!;
          } else {
            for (final t in metadata.tryFiles) {
              if (t.startsWith('/')) {
                servedFile = metadata.paths[t];
                break;
              }
              final p = path.isEmpty ? t : '$path/$t';

              if (metadata.paths.containsKey(p)) {
                servedFile = metadata.paths[p];
                break;
              }
            }

            if (servedFile == null) {
              if (metadata.errorPages.containsKey(404)) {
                res.statusCode = 404;
                servedFile =
                    metadata.paths[metadata.errorPages[404]!.substring(1)];
              }
            }
          }
          if (servedFile == null) {
            res.statusCode = 404;
            res.write('404 Not found');
            res.close();
            return;
          } else {
            res.headers.set(
              'content-type',
              servedFile.contentType ?? 'application/octet-stream',
            );

            res.headers.set(
              'content-length',
              servedFile.size.toString(),
            );

            res.headers.set(
              'etag',
              '"${servedFile.cid.hash.toBase64Url()}"',
            );

            if (servedFile.cid.size == null ||
                servedFile.cid.size! <= defaultChunkSize) {
              res.add(await node.downloadBytesByHash(servedFile.cid.hash));
              res.close();
            } else {
              await handleChunkedFile(
                request,
                res,
                servedFile.cid.hash,
                servedFile.cid.size!,
                cachePath: join(cachePath, 'streamed_files'),
                logger: node.logger,
                node: node,
              );
            }
            return;
          }
        }
      } catch (e) {
        try {
          request.response.statusCode = 500;
          request.response.write(e.toString());
          await request.response.close();
        } catch (_) {}
        return;
      }

      app.requestQueue.add(() => app.incomingRequest(request));
    });

    app.logWriter(
      () => 'HTTP API Server listening on port ${_server.port}',
      LogType.info,
    );
    app.server = _server;
  }

  void setUnlimitedCacheHeader(HttpResponse res) {
    res.headers.set(
      'Cache-Control',
      'public, max-age=31536000',
    );
  }
}

class TusUploadSession {
  int get offset => cacheFile.lengthSync();
  final Multihash expectedHash;
  final int totalLength;
  final File cacheFile;
  final Account? account;

  TusUploadSession({
    required this.totalLength,
    required this.expectedHash,
    required this.cacheFile,
    this.account,
  });
}
