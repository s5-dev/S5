// TODO Improve this implementation, it's pretty inefficient

enum EndianType { littleEndian, bigEndian }

String getHexString(int n, int k) {
  if (n < 0) {
    n = int.tryParse('0x1' + '00' * k)! + n;
  }

  var str = n.toRadixString(16);

  if (str.length % 2 == 1) {
    str = '0' + str;
  }
  return str;
}

Iterable<int?> convertHexString2Bytes(String hexString) {
  return RegExp(r'.{1,2}').allMatches(hexString).map((x) {
    return int.tryParse(x[0]!, radix: 16);
  });
}

List<int?> convertBytesEndianType(
    Iterable<int?> bytes, int k, EndianType endianType) {
  switch (endianType) {
    case EndianType.littleEndian:
      var ret = List<int>.from(bytes).reversed.toList();
      ret.addAll(List<int>.filled(k - bytes.length, 0));
      return ret;
    case EndianType.bigEndian:
    default:
      var ret = List<int?>.filled(k - bytes.length, 0, growable: true);
      ret.addAll(bytes);
      return ret;
  }
}
