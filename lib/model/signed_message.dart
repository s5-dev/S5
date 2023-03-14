import 'dart:typed_data';

import 'package:lib5/lib5.dart';

class SignedMessage {
  final NodeID nodeId;
  final Uint8List message;

  SignedMessage({required this.nodeId, required this.message});
}
