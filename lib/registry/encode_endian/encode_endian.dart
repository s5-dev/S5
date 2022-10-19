import 'base.dart';

// TODO Improve this implementation, it's pretty inefficient

List<int?> encodeEndian(int n, int k, {endianType = EndianType.bigEndian}) {
  var hexStr = getHexString(n, k);
  var bytes = convertHexString2Bytes(hexStr);

  return convertBytesEndianType(bytes, k, endianType);
}
