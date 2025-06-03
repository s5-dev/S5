import 'dart:async';
import 'dart:io';

import 'package:belatuk_range_header/belatuk_range_header.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';

import 'package:s5_server/download/open_read.dart';
import 'package:s5_server/node.dart';

Future handleChunkedFile(
  HttpRequest req,
  HttpResponse res,
  Multihash hash,
  int totalSize, {
  required String cachePath,
  required Logger logger,
  required S5Node node,
}) async {
  final rangeHeader = req.headers.value('range');

  final completer = Completer();

  if (rangeHeader?.startsWith('bytes=') != true) {
    res.headers.add('content-length', totalSize);
    await res.addStream(openRead(
      mhash: hash,
      start: 0,
      totalSize: totalSize,
      completer: completer,
      cachePath: cachePath,
      node: node,
    ));
    completer.complete();
    return res.close();
  } else {
    var header = RangeHeader.parse(rangeHeader!);
    final items = RangeHeader.foldItems(header.items);
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

      if (item.end >= totalSize) {
        res.headers.add('content-length', totalSize);

        await res.addStream(openRead(
          mhash: hash,
          start: 0,
          totalSize: totalSize,
          completer: completer,
          cachePath: cachePath,
          node: node,
        ));
        completer.complete();
        return res.close();
      }

      // Ensure it's within range.
      if (item.start >= totalSize || item.end >= totalSize) {
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

      if (item.start == -1) {
        if (item.end == -1) {
          len = totalSize;
          stream = openRead(
            mhash: hash,
            start: 0,
            totalSize: totalSize,
            completer: completer,
            cachePath: cachePath,
            node: node,
          );
        } else {
          len = item.end + 1;
          stream = openRead(
            mhash: hash,
            start: 0,
            end: item.end + 1,
            totalSize: totalSize,
            completer: completer,
            cachePath: cachePath,
            node: node,
          );
        }
      } else {
        if (item.end == -1) {
          len = totalSize - item.start;
          stream = openRead(
            mhash: hash,
            start: item.start,
            totalSize: totalSize,
            completer: completer,
            cachePath: cachePath,
            node: node,
          );
        } else {
          len = item.end - item.start + 1;
          stream = openRead(
            mhash: hash,
            start: item.start,
            end: item.end + 1,
            totalSize: totalSize,
            completer: completer,
            cachePath: cachePath,
            node: node,
          );
        }
      }

      res.statusCode = 206;
      res.headers.add('content-length', len.toString());
      res.headers.add(
        'content-range',
        'bytes ${item.toContentRange(totalSize)}',
      );
      await res.addStream(stream);
      completer.complete();
      return res.close();
    } else {}
  }
}
