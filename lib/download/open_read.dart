import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:path/path.dart';

import 'package:s5_server/download/uri_provider.dart';
import 'package:s5_server/node.dart';

final httpClient = Client();

final baoOutboardBytesCache = <String, Uint8List>{};
final downloadingChunkLock = <String, bool>{};

Stream<List<int>> openRead({
  int start = 0,
  int? end,
  required Multihash mhash,
  required int totalSize,
  required Completer completer,
  EncryptedCID? encryptionMetadata,
  required S5Node node,
  required String? cachePath,
}) async* {
  int endPos = end ?? totalSize;

  final isEncrypted = encryptionMetadata != null;

  final hash = encryptionMetadata?.encryptedBlobHash ?? mhash;

  if (totalSize <= 262144 && !isEncrypted) {
    File? cacheFile;

    if (cachePath != null) {
      cacheFile = File(join(cachePath, 'small-files', hash.toBase32()));
      node.logger.verbose('[openRead] small file');

      if (cacheFile.existsSync()) {
        if (start == 0) {
          if (endPos == cacheFile.lengthSync()) {
            yield* cacheFile.openRead();
          } else {
            yield* cacheFile.openRead(0, endPos);
          }
        } else {
          yield* cacheFile.openRead(start, endPos);
        }

        return;
      }
    }
    final dlUriProvider = StorageLocationProvider(node, hash, [
      storageLocationTypeFile,
      storageLocationTypeFull,
    ]);

    dlUriProvider.start();

    final loc = await dlUriProvider.next();

    final res = await httpClient.get(Uri.parse(loc.location.bytesUrl));

    final blake3Hash = await node.crypto.hashBlake3(res.bodyBytes);

    final isValid = areBytesEqual(hash.hashBytes, blake3Hash);

    if (isValid != true) {
      throw 'File integrity check failed (BLAKE3)';
    }

    if (start == 0) {
      if (endPos == res.bodyBytes.length) {
        yield res.bodyBytes;
      } else {
        yield res.bodyBytes.sublist(0, endPos);
      }
    } else {
      yield res.bodyBytes.sublist(start, endPos);
    }
    if (cacheFile != null) {
      cacheFile.parent.createSync(recursive: true);
      await cacheFile.writeAsBytes(res.bodyBytes);
    }

    return;
  }

  node.logger.verbose('[openRead] file');

  const chunkSize = 262144; // TODO Support custom chunk sizes

  int chunk = (start / chunkSize).floor();
  int offset = start % chunkSize;

  final downloadedEncData = <int>[];

  StorageLocationProvider? storageLocationProvider;

  SignedStorageLocation? storageLocation;

  bool downloadStarted = false;

  final cacheDirectory = cachePath == null
      ? null
      : Directory(join(
          cachePath,
          isEncrypted ? 's5-large-files-encrypted' : 's5-large-files',
          hash.toBase32()));

  cacheDirectory?.createSync(recursive: true);

  final lockedChunks = <String>[];

  StreamSubscription? sub;

  while (start < endPos) {
    if (completer.isCompleted) {
      sub?.cancel();

      for (final key in lockedChunks) {
        downloadingChunkLock.remove(key);
      }
      downloadedEncData.clear();
      return;
    }

    final chunkCacheFile = cacheDirectory == null
        ? null
        : File(join(cacheDirectory.path, chunk.toString()));

    if (chunkCacheFile?.existsSync() ?? false) {
      if (offset == 0) {
        if ((start + chunkCacheFile!.lengthSync()) > endPos) {
          yield* chunkCacheFile.openRead(0, (endPos % chunkSize));
        } else {
          yield* chunkCacheFile.openRead();
        }
      } else {
        if (((start - offset) + chunkCacheFile!.lengthSync()) > endPos) {
          yield* chunkCacheFile.openRead(offset, (endPos % chunkSize));
        } else {
          yield* chunkCacheFile.openRead(offset);
        }
      }
      start += chunkSize - offset;
    } else {
      final chunkLockKey = '${hash.toBase64Url()}/$chunk';
      if (downloadingChunkLock[chunkLockKey] == true &&
          !lockedChunks.contains(chunkLockKey)) {
        // sub?.cancel();
        while (downloadingChunkLock[chunkLockKey] == true) {
          // TODO Risk for infinite loop, add timeout
          await Future.delayed(Duration(milliseconds: 10));
        }

        if (offset == 0) {
          if ((start + chunkCacheFile!.lengthSync()) > endPos) {
            yield* chunkCacheFile.openRead(0, (endPos % chunkSize));
          } else {
            yield* chunkCacheFile.openRead();
          }
        } else {
          if (((start - offset) + chunkCacheFile!.lengthSync()) > endPos) {
            yield* chunkCacheFile.openRead(offset, (endPos % chunkSize));
          } else {
            yield* chunkCacheFile.openRead(offset);
          }
        }
        start += chunkSize - offset;
      } else {
        if (storageLocationProvider == null) {
          storageLocationProvider = StorageLocationProvider(
              node,
              hash,
              isEncrypted
                  ? [
                      storageLocationTypeFile,
                      storageLocationTypeFull,
                    ]
                  : [
                      storageLocationTypeFull,
                    ]);

          storageLocationProvider.start();
        }
        if (storageLocation == null) {
          storageLocation = await storageLocationProvider.next();
        }

        void lockChunk(int index) {
          final chunkLockKey = '${hash.toBase64Url()}/$index';
          downloadingChunkLock[chunkLockKey] = true;
          lockedChunks.add(chunkLockKey);
        }

        lockChunk(chunk);

        if (!isEncrypted &&
            baoOutboardBytesCache[storageLocation.location.outboardBytesUrl] ==
                null) {
          final baoLockKey = '${hash.toBase64Url()}/bao';
          if (downloadingChunkLock[baoLockKey] == true) {
            while (downloadingChunkLock[baoLockKey] == true) {
              // TODO Risk for infinite loop, add timeout
              await Future.delayed(Duration(milliseconds: 10));
            }
          } else {
            downloadingChunkLock[baoLockKey] = true;
            lockedChunks.add(baoLockKey);

            final res = await httpClient
                .get(Uri.parse(storageLocation.location.outboardBytesUrl));
            // TODO Verify integrity here

            baoOutboardBytesCache[storageLocation.location.outboardBytesUrl] =
                res.bodyBytes;

            downloadingChunkLock.remove(baoLockKey);
          }
        }
        Uint8List chunkBytes;
        int retryCount = 0;

        while (true) {
          try {
            node.logger.verbose('[chunk] download $chunk');

            final startByte = chunk * chunkSize;

            final encStartByte =
                isEncrypted ? chunk * (chunkSize + 16) : startByte;

            final encChunkSize = isEncrypted ? chunkSize + 16 : chunkSize;

            bool hasDownloadError = false;

            if (downloadStarted == false) {
              String rangeHeader;

              if (endPos < (startByte + chunkSize)) {
                if ((startByte + chunkSize) > totalSize) {
                  rangeHeader = 'bytes=$encStartByte-';
                } else {
                  rangeHeader =
                      'bytes=$encStartByte-${encStartByte + encChunkSize - 1}';
                }
              } else {
                final downloadUntilChunkExclusive =
                    (endPos / chunkSize).floor() + 1;

                for (int ci = chunk + 1;
                    ci < downloadUntilChunkExclusive;
                    ci++) {
                  lockChunk(ci);
                }

                final length =
                    encChunkSize * (downloadUntilChunkExclusive - chunk);

                if ((encStartByte + length) > totalSize) {
                  rangeHeader = 'bytes=$encStartByte-';
                } else {
                  rangeHeader =
                      'bytes=$encStartByte-${encStartByte + length - 1}';
                }
              }
              node.logger.verbose('[openRead] fetch range $rangeHeader');

              final request =
                  Request('GET', Uri.parse(storageLocation.location.bytesUrl));
              request.headers['range'] = rangeHeader;

              downloadStarted = true;

              final response = await httpClient.send(request);

              if (![206, 200].contains(response.statusCode)) {
                throw 'HTTP ${response.statusCode}';
              }
              sub = response.stream.listen(
                (value) {
                  downloadedEncData.addAll(value);
                },
                // onDone: () {},
                onError: (e, st) {
                  hasDownloadError = true;
                  node.logger.catched(e, st);
                },
              );
            }

            final isLastChunk = (startByte + chunkSize) > (totalSize);

            if (isLastChunk) {
              while (downloadedEncData.length < (totalSize - encStartByte)) {
                if (hasDownloadError) throw 'Download HTTP request failed';
                await Future.delayed(Duration(milliseconds: 10));
              }
            } else {
              while (downloadedEncData.length < encChunkSize) {
                if (hasDownloadError) throw 'Download HTTP request failed';
                await Future.delayed(Duration(milliseconds: 10));
              }
            }

            chunkBytes = Uint8List.fromList(isLastChunk
                ? downloadedEncData
                : downloadedEncData.sublist(0, encChunkSize));

            if (isEncrypted) {
              final nonce = encodeEndian(chunk, 24);

              chunkBytes = await node.crypto.decryptXChaCha20Poly1305(
                  key: encryptionMetadata.encryptionKey,
                  nonce: nonce,
                  ciphertext: chunkBytes);
              if (isLastChunk && encryptionMetadata.padding > 0) {
                chunkBytes = chunkBytes.sublist(
                    0, chunkBytes.length - encryptionMetadata.padding);
              }
            } else {
              final integrityRes = await node.rust.verifyIntegrity(
                chunkBytes: chunkBytes,
                offset: chunk * chunkSize,
                baoOutboardBytes: baoOutboardBytesCache[
                    storageLocation.location.outboardBytesUrl]!,
                blake3Hash: hash.hashBytes,
              );

              if (integrityRes != 1) {
                throw "File integrity check failed (BLAKE3-BAO with WASM)";
              }
            }
            storageLocationProvider.upvote(storageLocation);

            if (isLastChunk) {
              await chunkCacheFile?.writeAsBytes(chunkBytes);
              downloadedEncData.clear();
            } else {
              await chunkCacheFile?.writeAsBytes(chunkBytes);
              downloadedEncData.removeRange(0, encChunkSize);
            }

            try {
              if (offset == 0) {
                if ((start + chunkBytes.length) > endPos) {
                  yield chunkBytes.sublist(0, (endPos % chunkSize));
                } else {
                  yield chunkBytes;
                }
              } else {
                if (((start - offset) + chunkBytes.length) > endPos) {
                  yield chunkBytes.sublist(offset, (endPos % chunkSize));
                } else {
                  yield chunkBytes.sublist(offset);
                }
              }
            } catch (e) {
              for (final key in lockedChunks) {
                downloadingChunkLock.remove(key);
              }
              node.logger.warn(e.toString());
              if (downloadedEncData.isEmpty) {
                return;
              }
            }
            start += chunkSize - offset;

            downloadingChunkLock.remove(chunkLockKey);

            break;
          } catch (e, st) {
            storageLocationProvider.downvote(storageLocation);
            node.logger.catched(e, st);
            retryCount++;
            if (retryCount > 10) {
              for (final key in lockedChunks) {
                downloadingChunkLock.remove(key);
              }
              throw 'Too many retries. ($e)';
            }

            downloadedEncData.clear();
            downloadStarted = false;

            node.logger.error(
              '[chunk] download error for chunk $chunk (try #$retryCount)',
            );

            await Future.delayed(
                Duration(milliseconds: pow(2, retryCount + 5) as int));
          }
        }
      }
    }
    offset = 0;
    chunk++;
  }
}
