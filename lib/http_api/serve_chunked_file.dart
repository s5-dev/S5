import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:belatuk_range_header/belatuk_range_header.dart';
import 'package:http/http.dart';
import 'package:path/path.dart';

import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/metadata.dart';
import 'package:s5_server/util/bytes.dart';

final httpClient = Client();

Future handleChunkedFile(
  HttpRequest req,
  HttpResponse res,
  DownloadUriProvider dlUriProvider,
  FileMetadata metadata, {
  required String cachePath,
  required Logger logger,
}) async {
  final totalSize = metadata.size;

  final rangeHeader = req.headers.value('range');

  if (rangeHeader?.startsWith('bytes=') != true) {
    res.headers.add('content-length', totalSize);
    await res.addStream(openRead(
      dlUriProvider,
      metadata,
      0,
      totalSize,
      cachePath: cachePath,
      logger: logger,
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
          metadata,
          0,
          totalSize,
          cachePath: cachePath,
          logger: logger,
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
            metadata,
            0,
            totalSize,
            cachePath: cachePath,
            logger: logger,
          );
        } else {
          len = item.end + 1;
          stream = openRead(
            dlUriProvider,
            metadata,
            0,
            item.end + 1,
            cachePath: cachePath,
            logger: logger,
          );
        }
      } else {
        if (item.end == -1) {
          len = total - item.start;
          stream = openRead(
            dlUriProvider,
            metadata,
            item.start,
            totalSize,
            cachePath: cachePath,
            logger: logger,
          );
        } else {
          len = item.end - item.start + 1;
          stream = openRead(
            dlUriProvider,
            metadata,
            item.start,
            item.end + 1,
            cachePath: cachePath,
            logger: logger,
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

Map<String, Completer> downloadingChunkLock = {};

Stream<List<int>> openRead(
  DownloadUriProvider dlUriProvider,
  FileMetadata metadata,
  int start,
  int totalSize, {
  required String cachePath,
  required Logger logger,
}) async* {
  final chunkSize = metadata.chunkSize;

  int chunk = (start / chunkSize).floor();

  int offset = start % chunkSize;

  DownloadURI downloadUri = await dlUriProvider.next();

  StreamSubscription? sub;

  final totalEncSize = totalSize;

  final downloadedEncData = <int>[];

  bool isDone = false;

  final outDir = Directory(join(
    cachePath,
    metadata.contentHash.toBase64Url(),
  ));

  outDir.createSync(recursive: true);

  while (start < totalSize) {
    final chunkCacheFile = File(join(outDir.path, chunk.toString()));

    if (!chunkCacheFile.existsSync()) {
      final chunkLockKey = '${metadata.contentHash.toBase64Url()}-$chunk';

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
              final request = Request('GET', downloadUri.uri);

              request.headers['range'] = 'bytes=$encStartByte-';

              final response = await httpClient.send(request);

              if (response.statusCode != 206) {
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

            final chunkHash = metadata.chunkHashes[chunk];

            final isValid = ensureIntegrity(chunkHash, bytes);

            if (!isValid) {
              throw 'Integrity verification failed';
            }

            dlUriProvider.upvote(downloadUri);
            await chunkCacheFile.writeAsBytes(bytes);

            completer.complete();
            break;
          } catch (e, st) {
            dlUriProvider.downvote(downloadUri);
            try {
              downloadUri = await dlUriProvider.next();
            } catch (e, st) {
              completer.complete();
              downloadingChunkLock.remove(chunkLockKey);
              throw 'Failed to download chunk. ($e $st)';
            }

            try {
              sub?.cancel();
            } catch (_) {}
            downloadedEncData.clear();

            logger.warn('[chunk] download error (try #$retryCount): $e $st');
            await Future.delayed(Duration(milliseconds: 10));
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
