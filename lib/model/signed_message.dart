import 'dart:typed_data';

class SignedMessage {
  final String nodeId;
  final Uint8List message;

  SignedMessage({required this.nodeId, required this.message});
}
