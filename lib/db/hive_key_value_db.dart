import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/lib5.dart';

class HiveKeyValueDB extends KeyValueDB {
  final Box<Uint8List> box;
  HiveKeyValueDB(this.box);

  @override
  bool contains(Uint8List key) => box.containsKey(String.fromCharCodes(key));

  @override
  Uint8List? get(Uint8List key) => box.get(String.fromCharCodes(key));

  @override
  void set(Uint8List key, Uint8List value) => box.put(
        String.fromCharCodes(key),
        value,
      );

  @override
  void delete(Uint8List key) {
    box.delete(String.fromCharCodes(key));
  }
}
