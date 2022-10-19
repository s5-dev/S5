import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
// ignore: implementation_imports
import 'package:alfred/src/type_handlers/websocket_type_handler.dart';
import 'package:messagepack/messagepack.dart';
import 'package:path/path.dart';

import 'package:s5_server/constants.dart';
import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/model/cid.dart';
import 'package:s5_server/model/metadata.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/registry/registry.dart';
import 'package:s5_server/util/uid.dart';
import 'package:s5_server/util/multipart.dart';

import 'serve_chunked_file.dart';

class HttpAPIServer {
  final S5Node node;

  HttpAPIServer(this.node);

  Future<void> start(String cachePath) async {
    final app = Alfred();

    app.get(
      '/',
      (req, res) => 'S5 Node is running! :) v$nodeVersion',
    );

    app.get(
      '/s5/version',
      (req, res) => {
        'node': nodeVersion,
        // 'api':
        // 'protocol':
      },
    );

    app.head('/s5/upload/directory', (req, res) => '');

    app.post('/s5/upload/directory', (req, res) async {
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
          dirname: queryParams['filename'],
        );

        return {
          'cid': cid.encode(),
        };
      } else {
        throw 'Not a multipart directory upload';
      }
    });

    // TODO Support uploads with tus

    app.head('/s5/upload', (req, res) => '');

    app.post('/s5/upload', (req, res) async {
      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }

      final body = (await req.body as Map);

      final HttpBodyFileUpload file = body['file'];

      final cacheFile = File(
        join(cachePath, 'upload', generateUID(), file.filename),
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
        'cid': cid.encode(),
      };
    });

    app.head('/s5/delete/:cid', (req, res) => '');

    app.delete('/s5/delete/:cid', (req, res) async {
      if (node.config['http']?['api']?['delete']?['enabled'] != true) {
        res.statusCode = HttpStatus.unauthorized;
        return 'Endpoint disabled in config.toml';
      }
      final cid = CID.decode(req.params['cid']);
      await node.deleteFile(cid);
    });

    app.head('/s5/pin/:cid', (req, res) => '');

    app.post('/s5/pin/:cid', (req, res) async {
      final cid = CID.decode(req.params['cid']);

      await node.pinFile(cid);
    });

    app.get(
      '/s5/debug/nodes',
      (req, res) => node.p2p.nodesBox.toMap().cast<String, dynamic>(),
    );

    app.get(
      '/s5/debug/objects',
      (req, res) => node.objectsBox.toMap().cast<String, dynamic>(),
    );

    app.head('/s5/raw/upload', (req, res) => '');

    app.post('/s5/raw/upload', (req, res) async {
      if (node.store == null) {
        throw 'No store configured, uploads not possible';
      }
      final HttpBodyFileUpload file = (await req.body as Map)['file'];

      final cid = await node.uploadRawFile(
        Uint8List.fromList(file.content is String
            ? (file.content as String).codeUnits
            : file.content),
      );

      return {
        'cid': cid.encode(),
      };
    });

    app.get('/:cid', (req, res) async {
      final cidStr = req.params['cid'];

      final cid = CID.decode(cidStr);

      if (cid.type == cidTypeRaw) {
        throw 'This is raw CID, use the /s5/raw/dl/:cid endpoint instead';
      }

      if (cid.type == cidTypeMetadataDirectory || cid.type == cidTypeResolver) {
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

      final hash = cid.hash;

      final metadata = await node.getMetadataByCID(cid) as FileMetadata;

      res.headers.set(
        'content-type',
        metadata.contentType ?? 'application/octet-stream',
      );

      res.headers.set(
        'content-disposition',
        'inline; filename="${metadata.filename ?? 'file'}"',
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

      // TODO date header

      final dlUriProvider = DownloadUriProvider(node, metadata.contentHash);

      dlUriProvider.start();

      await handleChunkedFile(
        req,
        res,
        dlUriProvider,
        metadata,
        cachePath: join(cachePath, 'stream'),
        logger: node.logger,
      );
    });

    app.get('/s5/metadata/:cid', (req, res) async {
      final cid = CID.decode(req.params['cid']);

      if (cid.type == cidTypeRaw) {
        throw 'Raw CIDs do not have metadata';
      } else if (cid.type == cidTypeResolver) {
        // TODO Support resolver CIDs
        throw 'This endpoint does not support resolver CIDs yet';
      }

      final metadata = await node.getMetadataByCID(cid);

      setUnlimitedCacheHeader(res);

      return metadata.toJson();
    });

    app.get('/s5/raw/dl/:cid', (req, res) async {
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

    app.get('/s5/registry', (req, res) async {
      final queryParams = req.uri.queryParameters;

      final pk = base64Url.decode(queryParams['pk']!);
      final dk = base64Url.decode(queryParams['dk']!);

      final entry = await node.registry.get(pk, dk);
      if (entry == null) {
        res.statusCode = 404;
        return '';
      }
      final response = <String, dynamic>{
        'pk': base64Url.encode(entry.pk),
        'dk': base64Url.encode(entry.dk),
        'revision': entry.revision,
        'data': base64Url.encode(entry.data),
        'signature': base64Url.encode(entry.signature),
      };

      return response;
    });

    app.head('/s5/registry', (req, res) => '');

    app.post('/s5/registry', (req, res) async {
      final map = await req.bodyAsJsonMap;

      final pk = base64Url.decode(map['pk']!);
      final dk = base64Url.decode(map['dk']!);

      final int revision = map['revision']!;
      final bytes = base64Url.decode(map['data']!);
      final signature = base64Url.decode(map['signature']!);

      await node.registry.set(
        SignedRegistryEntry(
          pk: pk,
          dk: dk,
          revision: revision,
          data: bytes,
          signature: signature,
        ),
      );
      res.statusCode = 204;
    });

    app.get('/s5/registry/subscription', (req, res) {
      return WebSocketSession(
        onOpen: (ws) {},
        onMessage: (webSocket, data) {
          final u = Unpacker(data);
          final method = u.unpackInt();
          if (method == 2) {
            final stream = node.registry.listen(
              Uint8List.fromList(u.unpackBinary()),
              Uint8List.fromList(u.unpackBinary()),
            );
            webSocket.addStream(stream.map((sre) {
              return node.registry.prepareMessage(sre);
            }));
          }
        },
        onClose: (ws) {
          // TODO Clean up subscriptions
        },
      );
    });

    final _server = await HttpServer.bind(
      node.config['http']?['api']?['bind'] ?? '127.0.0.1',
      node.config['http']?['api']?['port'] ?? 5522,
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

        final additionalHeaders = {
          'access-control-allow-methods':
              'GET, POST, HEAD, OPTIONS, PUT, PATCH, DELETE',
          'access-control-allow-headers':
              'User-Agent,X-Requested-With,If-Modified-Since,If-None-Match,Cache-Control,Content-Type,Range,X-HTTP-Method-Override,upload-offset,upload-metadata,upload-length,tus-version,tus-resumable,tus-extension,tus-max-size,upload-concat,location',
          'access-control-expose-headers':
              'Content-Length,Content-Range,ETag,Accept-Ranges,upload-offset,upload-metadata,upload-length,tus-version,tus-resumable,tus-extension,tus-max-size,upload-concat,location',
          'access-control-allow-credentials': 'true',
        };
        for (final h in additionalHeaders.entries) {
          res.headers.set(h.key, h.value);
        }

        res.headers.removeAll('x-frame-options');
        res.headers.removeAll('x-xss-protection');

        if (request.method == 'OPTIONS') {
          res.statusCode = 204;
          res.close();
          return;
        }
        CID? cid;

        final parts = uri.host.split('.');

        if (parts.length > 1 && parts[1] == 'hns') {
          final hnsName = parts[0];

          final cidStr = await node.resolveName(hnsName);

          cid = CID.decode(cidStr);
        }

        if (cid == null) {
          try {
            cid = CID.decode(parts[0]);
          } catch (_) {}
        }

        if (cid != null) {
          if (cid.type == cidTypeRaw) {
            throw 'Raw files can\'t be served on a subdomain. Try loading this CID on the root domain';
          } else if (cid.type == cidTypeMetadataFile) {
            throw 'Normal files can\'t be served on a subdomain. Try loading this CID on the root domain';
          }
          if (cid.type == cidTypeResolver) {
            final res = await node.registry.get(
              cid.hash.bytes,
              Uint8List(
                32,
              ),
            );
            if (res == null) {
              throw 'Registry entry is empty';
            }
            cid = CID.fromBytes(res.data.sublist(1));
          }

          final metadata =
              await node.getMetadataByCID(cid) as DirectoryMetadata;

          DirectoryMetadataFileReference? servedFile;

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

            final bytes = await node.downloadBytesByHash(servedFile.cid.hash);
            res.add(bytes);
            res.close();
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
