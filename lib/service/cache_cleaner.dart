import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:s5_server/logger/base.dart';

class CacheCleaner {
  final Directory cacheDirectory;
  final Logger logger;

  CacheCleaner(this.cacheDirectory, this.logger);

  final maxCacheSizeInGB = 4;

  void start() {
    run();
    Stream.periodic(Duration(minutes: 10)).listen((_) {
      run();
    });
  }

  void run() async {
    final clt = DateTime.now().subtract(Duration(hours: 8));

    if (!cacheDirectory.existsSync()) {
      cacheDirectory.createSync(recursive: true);
    }

    final allCacheFiles = await cacheDirectory.list(recursive: true).toList();

    allCacheFiles.removeWhere((element) => element is! File);

    int totalSize = allCacheFiles.fold(
      0,
      (previousValue, element) {
        if (element.path.contains('/tus_upload/')) {
          return previousValue;
        }
        return previousValue + (element as File).lengthSync();
      },
    );

    final maxCacheSize = (maxCacheSizeInGB * 1000 * 1000 * 1000).round();

    logger.verbose(
      '[cache] total used cache size: ${filesize(totalSize)} / ${filesize(maxCacheSize)}',
    );

    if (totalSize < maxCacheSize) {
      logger.verbose(
        '[cache] doing nothing because max cache size is not reached yet',
      );
      return;
    }

    allCacheFiles.sort(
      (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
    );

    // TODO Delete empty directories

    while (totalSize > maxCacheSize) {
      if (allCacheFiles.isEmpty) {
        break;
      }
      final File file = allCacheFiles.removeAt(0) as File;
      if (file.path.contains('/upload/') ||
          file.path.contains('/tus_upload/')) {
        if (file.statSync().modified.isAfter(clt)) {
          continue;
        }
      }
      totalSize -= file.lengthSync();
      logger.verbose('[cache] delete ${file.path}');

      await file.delete();
    }
  }
}
