import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:belatuk_range_header/belatuk_range_header.dart';
import 'package:http/http.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:path/path.dart';

import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/node.dart';

final httpClient = Client();

Future handleChunkedFile(
  HttpRequest req,
  HttpResponse res,
  Multihash hash,
  int totalSize,
  StorageLocationProvider dlUriProvider, {
  required String cachePath,
  required Logger logger,
  required S5Node node,
}) async {
  final rangeHeader = req.headers.value('range');

  if (rangeHeader?.startsWith('bytes=') != true) {
    res.headers.add('content-length', totalSize);
    await res.addStream(openRead(
      dlUriProvider,
      hash: hash,
      start: 0,
      totalSize: totalSize,
      cachePath: cachePath,
      logger: logger,
      node: node,
    ));
    return res.close();
  } else {
    var header = RangeHeader.parse(rangeHeader!);
    final items = RangeHeader.foldItems(header.items);
    var totalFileSize = totalSize;
    header = RangeHeader(items);

    for (var item in header.items) {
      var invalid = false;

      if (item.start != -1) {
        invalid = item.end != -1 && item.end < item.start;
      } else {
        invalid = item.end == -1;
      }

      if (invalid) {
        res.statusCode = 416;
        res.write('416 Semantically invalid, or unbounded range.');
        return res.close();
      }

      if (item.end >= totalFileSize) {
        res.headers.add('content-length', totalSize);

        await res.addStream(openRead(
          dlUriProvider,
          hash: hash,
          start: 0,
          totalSize: totalSize,
          cachePath: cachePath,
          logger: logger,
          node: node,
        ));
        return res.close();
      }

      // Ensure it's within range.
      if (item.start >= totalFileSize || item.end >= totalFileSize) {
        res.statusCode = 416;
        res.write('416 Given range $item is out of bounds.');
        return res.close();
      }
    }

    if (header.items.isEmpty) {
      res.statusCode = 416;
      res.write('416 `Range` header may not be empty.');
      return res.close();
    } else if (header.items.length == 1) {
      var item = header.items[0];

      Stream<List<int>> stream;
      var len = 0;

      var total = totalFileSize;

      if (item.start == -1) {
        if (item.end == -1) {
          len = total;
          stream = openRead(
            dlUriProvider,
            hash: hash,
            start: 0,
            totalSize: totalSize,
            cachePath: cachePath,
            logger: logger,
            node: node,
          );
        } else {
          len = item.end + 1;
          stream = openRead(
            dlUriProvider,
            hash: hash,
            start: 0,
            totalSize: item.end + 1,
            cachePath: cachePath,
            logger: logger,
            node: node,
          );
        }
      } else {
        if (item.end == -1) {
          len = total - item.start;
          stream = openRead(
            dlUriProvider,
            hash: hash,
            start: item.start,
            totalSize: totalSize,
            cachePath: cachePath,
            logger: logger,
            node: node,
          );
        } else {
          len = item.end - item.start + 1;
          stream = openRead(
            dlUriProvider,
            hash: hash,
            start: item.start,
            totalSize: item.end + 1,
            cachePath: cachePath,
            logger: logger,
            node: node,
          );
        }
      }

      res.statusCode = 206;
      res.headers.add('content-length', len.toString());
      res.headers.add(
        'content-range',
        'bytes ' + item.toContentRange(total),
      );
      await stream.cast<List<int>>().pipe(res);
      return res.close();
    } else {}
  }
}

final merkleTreeCache = <String, TreeMetadata>{};

class TreeMetadata {
  final Uint8List baoBytes;

  TreeMetadata(this.baoBytes);
}

Map<String, Completer> downloadingChunkLock = {};

Stream<List<int>> openRead(
  StorageLocationProvider dlUriProvider, {
  required Multihash hash,
  required int start,
  required int totalSize,
  required String cachePath,
  required Logger logger,
  required S5Node node,
}) async* {
  // TODO Read chunkSize from tree metadata
  final chunkSize = 256 * 1024;

  int chunk = (start / chunkSize).floor();

  int offset = start % chunkSize;

  var storageLocation = await dlUriProvider.next();

  if (!merkleTreeCache
      .containsKey(storageLocation.location.outboardBytesUrl.toString())) {
    final res = await httpClient.get(
      Uri.parse(
        storageLocation.location.outboardBytesUrl,
      ),
    );

    // TODO Verify bao bytes early
    merkleTreeCache[storageLocation.location.outboardBytesUrl.toString()] =
        TreeMetadata(res.bodyBytes);
  }

  final mtree =
      merkleTreeCache[storageLocation.location.outboardBytesUrl.toString()]!;

  StreamSubscription? sub;

  final totalEncSize = totalSize;

  final downloadedEncData = <int>[];

  bool isDone = false;

  final cacheDir = Directory(join(cachePath, hash.toBase32()));

  cacheDir.createSync(recursive: true);

  while (start < totalSize) {
    final chunkCacheFile = File(join(cacheDir.path, '$chunk'));

    if (!chunkCacheFile.existsSync()) {
      final chunkLockKey = '${hash.toBase64Url()}-$chunk';

      if (downloadingChunkLock.containsKey(chunkLockKey)) {
        logger.verbose('[chunk] wait $chunk');

        sub?.cancel();
        while (!downloadingChunkLock[chunkLockKey]!.isCompleted) {
          await Future.delayed(Duration(milliseconds: 10));
        }
      } else {
        final completer = Completer();
        downloadingChunkLock[chunkLockKey] = completer;

        int retryCount = 0;

        while (true) {
          // TODO Check if retry makes sense with multi-chunk streaming
          try {
            logger.verbose('[chunk] dl $chunk');
            final encChunkSize = (chunkSize);
            final encStartByte = chunk * encChunkSize;

            final end = min(encStartByte + encChunkSize - 1, totalEncSize - 1);

            bool hasDownloadError = false;

            if (downloadedEncData.isEmpty) {
              logger.verbose('[chunk] send http range request');
              final request =
                  Request('GET', Uri.parse(storageLocation.location.bytesUrl));

              final range = 'bytes=$encStartByte-$totalSize';

              request.headers['range'] = range;

              final response = await httpClient.send(request);

              if (![200, 206].contains(response.statusCode)) {
                throw 'HTTP ${response.statusCode}';
              }

              final maxMemorySize = (32 * (chunkSize));

              sub = response.stream.listen(
                (value) {
                  // TODO Stop request when too fast
                  if (downloadedEncData.length > maxMemorySize) {
                    sub?.cancel();
                    downloadedEncData.removeRange(
                        maxMemorySize, downloadedEncData.length);
                    return;
                  }
                  downloadedEncData.addAll(value);
                },
                onDone: () {
                  isDone = true;
                },
                onError: (e, st) {
                  hasDownloadError = true;
                  logger.warn('[chunk] $e $st');
                },
              );
            }
            bool isLastChunk = (end + 1) == totalEncSize;

            if (isLastChunk) {
              while (!isDone) {
                if (hasDownloadError) throw 'Download HTTP request failed';
                await Future.delayed(Duration(milliseconds: 10));
              }
            } else {
              while (downloadedEncData.length < (chunkSize)) {
                if (hasDownloadError) throw 'Download HTTP request failed';
                await Future.delayed(Duration(milliseconds: 10));
              }
            }

            final bytes = Uint8List.fromList(
              isLastChunk
                  ? downloadedEncData
                  : downloadedEncData.sublist(0, (chunkSize)),
            );
            if (isLastChunk) {
              downloadedEncData.clear();
            } else {
              downloadedEncData.removeRange(0, (chunkSize));
            }

            final res = await node.rust.verifyIntegrity(
              chunkBytes: bytes,
              offset: chunk * chunkSize,
              baoOutboardBytes: mtree.baoBytes,
              blake3Hash: hash.hashBytes,
            );
            if (res != 1) {
              throw 'Invalid bytes';
            }

            dlUriProvider.upvote(storageLocation);
            await chunkCacheFile.writeAsBytes(bytes);

            completer.complete();
            break;
          } catch (e, st) {
            dlUriProvider.downvote(storageLocation);
            try {
              if (retryCount > 10) {
                rethrow;
              }
              storageLocation = await dlUriProvider.next();
            } catch (e, st) {
              completer.complete();
              downloadingChunkLock.remove(chunkLockKey);
              throw 'Failed to download chunk. ($e $st)';
            }

            try {
              sub?.cancel();
            } catch (_) {}
            downloadedEncData.clear();

            retryCount++;

            logger.warn('[chunk] download error (try #$retryCount): $e $st');
            await Future.delayed(
                Duration(milliseconds: pow(2, retryCount + 5) as int));
          }
        }
      }
    } else {
      sub?.cancel();
    }

    start += chunkCacheFile.lengthSync() - offset;

    if (start > totalSize) {
      final end = chunkCacheFile.lengthSync() - (start - totalSize);
      logger.verbose('[chunk] limit to $end');
      yield* chunkCacheFile.openRead(
        offset,
        end,
      );
    } else {
      yield* chunkCacheFile.openRead(
        offset,
      );
    }

    offset = 0;

    chunk++;
  }

  sub?.cancel();
}
