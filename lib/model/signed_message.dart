import 'dart:typed_data';

import 'package:s5_server/model/node_id.dart';

class SignedMessage {
  final NodeID nodeId;
  final Uint8List message;

  SignedMessage({required this.nodeId, required this.message});
}
