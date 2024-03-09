import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lib5/node.dart';
import 'package:lib5/util.dart';

class WebSocketPeer extends Peer {
  final WebSocket _socket;

  WebSocketPeer(
    this._socket, {
    required super.connectionUris,
  });

  @override
  void sendMessage(Uint8List message) {
    _socket.add(message);
  }

  @override
  void listenForMessages(
    Function callback, {
    dynamic onDone,
    Function? onError,
    required Logger logger,
  }) {
    final sub = _socket.listen(
      (event) async {
        await callback(event);
      },
      onDone: onDone,
      onError: onError,
      cancelOnError: false,
    );
  }

  @override
  String renderLocationUri() {
    return 'WebSocket client';
  }
}

class NativeP2PService extends P2PService {
  NativeP2PService(super.node);

  @override
  Future<void> start() async {
    final String? domain = node.config['http']?['api']?['domain'];
    if (domain != null && node.config['p2p']?['self']?['disabled'] != true) {
      selfConnectionUris.add(
        Uri.parse('wss://$domain/s5/p2p'),
      );
    }

    logger.info('connection uris: $selfConnectionUris');

    final initialPeers = node.config['p2p']?['peers']?['initial'] ?? [];

    for (final p in initialPeers) {
      connectToNode([Uri.parse(p)]);
    }
  }
}
