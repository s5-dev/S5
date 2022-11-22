import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:messagepack/messagepack.dart';
import 'package:tint/tint.dart';

import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/node_id.dart';
import 'package:s5_server/model/signed_message.dart';
import 'package:s5_server/node.dart';

class Peer {
  late final NodeID id;

  final Socket socket;
  final List<Uri> connectionUris;

  bool isConnected = false;

  final connectedPeers = <NodeID>{};

  late final Uint8List challenge;

  Peer(
    this.socket, {
    required this.connectionUris,
  });
}

class P2PService {
  final S5Node node;

  late KeyPairEd25519 nodeKeyPair;

  P2PService(this.node);

  Logger get logger => node.logger;

  late final Box<Map> nodesBox;

  late final NodeID localNodeId;

  final peers = <NodeID, Peer>{};
  final reconnectDelay = <NodeID, int>{};

  final List<Uri> selfConnectionUris = [];

  // TODO clean this table after a while (default 1 hour)
  final hashQueryRoutingTable = <Multihash, List<NodeID>>{};

  Future<void> init() async {
    localNodeId = NodeID(nodeKeyPair.publicKey);

    nodesBox = await Hive.openBox('s5-nodes');
  }

  Future<void> start() async {
    final networkSelf = node.config['p2p']?['self']?['tcp'];

    if (networkSelf != null) {
      final socket = await ServerSocket.bind('0.0.0.0', networkSelf['port']);
      socket.listen(
        (peerSocket) {
          final p = Peer(
            peerSocket,
            connectionUris: [],
          );

          runZonedGuarded(
            () {
              onNewPeer(p, null);
            },
            (e, st) {
              logger.catched(e, st);
            },
          );
        },
        cancelOnError: false,
        onError: (e) {
          logger.warn(e);
        },
        // onDone: (){}
      );
      selfConnectionUris.add(
        Uri.parse('tcp://${networkSelf['ip']}:${networkSelf['port']}'),
      );

      logger.info('connection uris: $selfConnectionUris');
    }
    final initialPeers = node.config['p2p']?['peers']?['initial'] ?? [];

    for (final p in initialPeers) {
      connectToNode([Uri.parse(p)]);
    }
  }

  void onNewPeer(Peer peer, Function? reconnect) {
    peer.challenge = node.crypto.generateRandomBytes(32);

    final initialAuthPayloadPacker = Packer();
    initialAuthPayloadPacker.packInt(protocolMethodHandshakeOpen);
    initialAuthPayloadPacker.packBinary(peer.challenge);
    peer.socket.add(initialAuthPayloadPacker.takeBytes());

    peer.socket.listen(
      (event) async {
        Unpacker u = Unpacker(event);
        final method = u.unpackInt();
        if (method == protocolMethodHandshakeOpen) {
          final p = Packer();
          p.packInt(protocolMethodHandshakeDone);
          p.packBinary(u.unpackBinary());
          p.packInt(selfConnectionUris.length);
          for (final uri in selfConnectionUris) {
            p.packString(uri.toString());
          }
          // TODO Protocol version
          // p.packInt(protocolVersion);
          peer.socket.add(await signMessage(p.takeBytes()));
          return;
        } else if (method == protocolMethodRegistryUpdate) {
          final sre = SignedRegistryEntry(
            pk: Uint8List.fromList(u.unpackBinary()),
            revision: u.unpackInt()!,
            data: Uint8List.fromList(u.unpackBinary()),
            signature: Uint8List.fromList(u.unpackBinary()),
          );
          node.registry.set(sre, receivedFrom: peer);
        }

        if (method == protocolMethodSignedMessage) {
          final sm = await unpackAndVerifySignature(u);
          u = Unpacker(sm.message);
          final method2 = u.unpackInt();

          if (method2 == protocolMethodHandshakeDone) {
            final challenge = Uint8List.fromList(u.unpackBinary());

            if (!areBytesEqual(peer.challenge, challenge)) {
              throw 'Invalid challenge';
            }

            final pId = sm.nodeId;
            if (reconnect == null) {
              peer.id = pId;
            } else {
              if (peer.id != pId) {
                throw 'Invalid peer id on initial list';
              }
            }

            peer.isConnected = true;

            peers[peer.id] = peer;
            reconnectDelay[peer.id] = 1;
            final connectionUrisCount = u.unpackInt()!;

            peer.connectionUris.clear();
            for (int i = 0; i < connectionUrisCount; i++) {
              peer.connectionUris.add(Uri.parse(u.unpackString()!));
            }

            logger.info(
              '${'[+]'.green().bold()} ${peer.id.toString().green()} (${(peer.connectionUris.isEmpty ? peer.socket.address.address : peer.connectionUris.first).toString().cyan()})',
            );

            sendPublicPeersToPeer(peer, peers.values);
            for (final p in peers.values) {
              if (p.id == peer.id) continue;

              if (p.isConnected) {
                sendPublicPeersToPeer(p, [peer]);
              }
            }

            return;
          } else if (method2 == protocolMethodHashQueryResponse) {
            final hash = Multihash(Uint8List.fromList(u.unpackBinary()));

            final ttl = u.unpackInt()!;

            final str = u.unpackString();

            if (str != null) {
              node.addDownloadUri(
                hash,
                sm.nodeId,
                str,
                ttl,
              );
            }

            final list = hashQueryRoutingTable[hash] ?? [];
            for (final peerId in list) {
              if (peers.containsKey(peerId)) {
                try {
                  peers[peerId]!.socket.add(event);
                } catch (e, st) {
                  logger.catched(e, st);
                }
              }
            }
          } else if (method2 == protocolMethodAnnouncePeers) {
            peer.connectedPeers.clear();
            final length = u.unpackInt()!;
            for (int i = 0; i < length; i++) {
              final peerIdBinary = u.unpackBinary();
              final id = NodeID(Uint8List.fromList(peerIdBinary));

              final isConnected = u.unpackBool()!;

              if (isConnected) {
                peer.connectedPeers.add(id);
              }
              final connectionUrisCount = u.unpackInt()!;

              final connectionUris = <Uri>[];

              for (int i = 0; i < connectionUrisCount; i++) {
                connectionUris.add(Uri.parse(u.unpackString()!));
              }

              if (connectionUris.isNotEmpty) {
                // TODO Fully support multiple connection uris
                final uri =
                    connectionUris.first.replace(userInfo: id.toBase58());
                if (!reconnectDelay.containsKey(NodeID.decode(uri.userInfo))) {
                  connectToNode([uri]);
                }
              }
            }
          }
        } else if (method == protocolMethodHashQuery) {
          final hash = Multihash(Uint8List.fromList(u.unpackBinary()));

          final contains = node.exposeStore && await node.store!.contains(hash);
          if (!contains) {
            hashQueryRoutingTable[hash] =
                (hashQueryRoutingTable[hash] ?? []) + [peer.id];

            for (final p in peers.values) {
              if (p.id != peer.id && !peer.connectedPeers.contains(p.id)) {
                p.socket.add(event);
              }
            }

            return;
          }

          final result = await node.store!.provide(hash);

          logger.verbose('[providing] $hash');

          final p = Packer();
          p.packInt(protocolMethodHashQueryResponse);
          p.packBinary(hash.fullBytes);
          p.packInt(
            DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
          );
          p.packString(result);

          peer.socket.add(await signMessage(p.takeBytes()));
        } else if (method == protocolMethodRegistryQuery) {
          final pk = Uint8List.fromList(u.unpackBinary());
          final sre = node.registry.getFromDB(pk);
          if (sre != null) {
            peer.socket.add(node.registry.prepareMessage(sre));
          }
        }
      },
      onDone: () async {
        try {
          if (peers.containsKey(peer.id)) {
            peers.remove(peer.id);
            logger.info(
              '${'[-]'.red().bold()} ${peer.id.toString().red()} (${(peer.connectionUris.isEmpty ? peer.socket.address.address : peer.connectionUris.first).toString().cyan()})',
            );
          }
        } catch (_) {
          logger.info('[-] ${peer.socket.address.address}');
        }
        if (reconnect != null) {
          final delay = reconnectDelay[peer.id] ?? 1;

          reconnectDelay[peer.id] = delay * 2;

          await Future.delayed(Duration(seconds: delay));
          reconnect();
        }
      },
      onError: (e) {
        logger.warn('${peer.id}: $e');
      },
      cancelOnError: false,
    );
  }

  void sendPublicPeersToPeer(Peer peer, Iterable<Peer> peersToSend) async {
    final p = Packer();
    p.packInt(protocolMethodAnnouncePeers);

    p.packInt(peersToSend.length);
    for (final pts in peersToSend) {
      p.packBinary(pts.id.bytes);
      p.packBool(pts.isConnected);
      p.packInt(pts.connectionUris.length);
      for (final uri in pts.connectionUris) {
        p.packString(uri.toString());
      }
    }
    peer.socket.add(await signMessage(p.takeBytes()));
  }

  // TODO nodes with a score below 0.2 should be disconnected immediately and responses dropped

  double getNodeScore(NodeID nodeId) {
    if (nodeId == localNodeId) {
      return 1;
    }
    final p = nodesBox.get(nodeId.toBase58()) ?? {};
    return calculateScore(p['+'] ?? 0, p['-'] ?? 0);
  }

  void incrementScoreCounter(NodeID nodeId, String type) {
    final p = nodesBox.get(nodeId.toBase58()) ?? {};
    p[type] = (p[type] ?? 0) + 1;

    nodesBox.put(nodeId.toBase58(), p);
  }

  // TODO add a bit of randomness with multiple options
  void sortNodesByScore(List<NodeID> nodes) {
    nodes.sort(
      (a, b) {
        return -getNodeScore(a).compareTo(getNodeScore(b));
      },
    );
  }

  Future<Uint8List> signMessage(Uint8List message) async {
    final packer = Packer();

    final signature = await node.crypto.signEd25519(
      kp: nodeKeyPair,
      message: message,
    );

    packer.packInt(protocolMethodSignedMessage);
    packer.packBinary(localNodeId.bytes);

    packer.packBinary(signature);
    packer.packBinary(message);

    return packer.takeBytes();
  }

  Future<SignedMessage> unpackAndVerifySignature(Unpacker u) async {
    final nodeId = NodeID(Uint8List.fromList(u.unpackBinary()));
    final signature = Uint8List.fromList(u.unpackBinary());
    final message = Uint8List.fromList(u.unpackBinary());

    final isValid = await node.crypto.verifyEd25519(
      pk: nodeId.bytes.sublist(1),
      message: message,
      signature: signature,
    );

    if (!isValid) {
      throw 'Invalid signature found';
    }
    return SignedMessage(
      nodeId: nodeId,
      message: message,
    );
  }

  void sendHashRequest(Multihash hash) {
    final p = Packer();

    p.packInt(protocolMethodHashQuery);
    p.packBinary(hash.fullBytes);

    final req = p.takeBytes();

    for (final peer in peers.values) {
      peer.socket.add(req);
    }
  }

  void connectToNode(List<Uri> connectionUris) async {
    final connectionUri = connectionUris.first;
    final protocol = connectionUri.scheme;
    if (protocol != 'tcp') {
      throw 'Protocol $protocol not supported';
    }
    if (connectionUri.userInfo.isEmpty) {
      throw 'Connection URI does not contain node id';
    }
    final id = NodeID.decode(connectionUri.userInfo);
    final ip = connectionUri.host;
    final port = connectionUri.port;

    if (id == localNodeId) {
      return;
    }
    runZonedGuarded(
      () async {
        reconnectDelay[id] ??= 1;

        logger.verbose('[connect] $connectionUri');

        final socket = await Socket.connect(ip, port);

        onNewPeer(
            Peer(
              socket,
              connectionUris: [connectionUri],
            )..id = id, () {
          connectToNode(connectionUris);
        });
      },
      (e, st) async {
        if (e is SocketException) {
          if (e.message == 'Connection refused') {
            logger.warn('[!] $id: $e');
            return;
          }
        }
        logger.catched(e, st);
      },
    );
  }
}
