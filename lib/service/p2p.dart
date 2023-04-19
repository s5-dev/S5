import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';
import 'package:messagepack/messagepack.dart';
import 'package:s5_server/db/hive_key_value_db.dart';
import 'package:tint/tint.dart';

import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/signed_message.dart';
import 'package:s5_server/node.dart';

class Peer {
  late final NodeID id;

  final Socket _socket;

  void sendMessage(Uint8List message) {
    _socket.add(encodeEndian(message.length, 4) + message);
  }

  void listenForMessages(
    Function callback, {
    dynamic onDone,
    Function? onError,
    required Logger logger,
  }) {
    final sub = _socket.listen(
      (event) async {
        int pos = 0;

        while (pos < event.length) {
          final length = decodeEndian(event.sublist(pos, pos + 4));

          if (event.length < (pos + 4 + length)) {
            print('Ignore message, invalid length (from $id)');
            return;
          }

          try {
            await callback(event.sublist(pos + 4, pos + 4 + length));
          } catch (e, st) {
            logger.catched(e, st, id.toBase58());
          }

          pos += length + 4;
        }
      },
      onDone: onDone,
      onError: onError,
      cancelOnError: false,
    );
  }

  final List<Uri> connectionUris;

  bool isConnected = false;

  late final Uint8List challenge;

  Peer(
    this._socket, {
    required this.connectionUris,
  });

  String renderLocationUri() {
    return connectionUris.isEmpty
        ? _socket.remoteAddress.address
        : connectionUris.first.toString();
  }
}

class P2PService {
  final S5Node node;

  late KeyPairEd25519 nodeKeyPair;

  P2PService(this.node);

  Logger get logger => node.logger;

  late final KeyValueDB nodesBox;

  late final NodeID localNodeId;

  final peers = <NodeID, Peer>{};
  final reconnectDelay = <NodeID, int>{};

  final List<Uri> selfConnectionUris = [];

  // TODO clean this table after a while (default 1 hour)
  final hashQueryRoutingTable = <Multihash, Set<NodeID>>{};

  Future<void> init() async {
    localNodeId = NodeID(nodeKeyPair.publicKey);

    nodesBox = HiveKeyValueDB(await Hive.openBox('s5-nodes'));
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
            () => onNewPeer(p, verifyId: false),
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

  Future<void> onNewPeer(Peer peer, {required bool verifyId}) async {
    peer.challenge = node.crypto.generateRandomBytes(32);

    final initialAuthPayloadPacker = Packer();
    initialAuthPayloadPacker.packInt(protocolMethodHandshakeOpen);
    initialAuthPayloadPacker.packBinary(peer.challenge);

    final completer = Completer();

    final supportedFeatures = 3; // 0b00000011

    peer.listenForMessages(
      (Uint8List event) async {
        Unpacker u = Unpacker(event);
        final method = u.unpackInt();
        if (method == protocolMethodHandshakeOpen) {
          final p = Packer();
          p.packInt(protocolMethodHandshakeDone);
          p.packBinary(u.unpackBinary());
          p.packInt(supportedFeatures);
          p.packInt(selfConnectionUris.length);
          for (final uri in selfConnectionUris) {
            p.packString(uri.toString());
          }
          // TODO Protocol version
          // p.packInt(protocolVersion);
          peer.sendMessage(await signMessageSimple(p.takeBytes()));
          return;
        } else if (method == recordTypeRegistryEntry) {
          final sre = node.registry.deserializeRegistryEntry(event);
          await node.registry.set(sre, receivedFrom: peer);
          return;
        } else if (method == recordTypeStorageLocation) {
          final hash = Multihash(event.sublist(1, 34));
          final type = event[34];
          final expiry = decodeEndian(event.sublist(35, 39));
          final partCount = event[39];
          final parts = <String>[];
          int cursor = 40;
          for (int i = 0; i < partCount; i++) {
            final length = decodeEndian(event.sublist(cursor, cursor + 2));
            cursor += 2;
            parts.add(utf8.decode(event.sublist(cursor, cursor + length)));
            cursor += length;
          }
          cursor++;

          final publicKey = event.sublist(cursor, cursor + 33);
          final signature = event.sublist(cursor + 33);

          if (publicKey[0] != mkeyEd25519) {
            throw 'Unsupported public key type $mkeyEd25519';
          }

          await node.crypto.verifyEd25519(
            pk: publicKey.sublist(1),
            message: event.sublist(0, cursor),
            signature: signature,
          );

          final nodeId = NodeID(publicKey);
          node.addStorageLocation(
            hash,
            nodeId,
            StorageLocation(type, parts, expiry),
            message: event,
          );

          final list = hashQueryRoutingTable[hash] ?? <NodeID>{};
          for (final peerId in list) {
            if (peerId == nodeId) continue;
            if (peerId == peer.id) continue;

            if (peers.containsKey(peerId)) {
              try {
                peers[peerId]!.sendMessage(event);
              } catch (e, st) {
                logger.catched(e, st);
              }
            }
          }
          hashQueryRoutingTable.remove(hash);
        }

        if (method == protocolMethodSignedMessage) {
          final sm = await unpackAndVerifySignature(u);
          u = Unpacker(sm.message);
          final method2 = u.unpackInt();

          if (method2 == protocolMethodHandshakeDone) {
            final challenge = u.unpackBinary();

            if (!areBytesEqual(peer.challenge, challenge)) {
              throw 'Invalid challenge';
            }

            final pId = sm.nodeId;

            if (!verifyId) {
              peer.id = pId;
            } else {
              if (peer.id != pId) {
                throw 'Invalid peer id on initial list';
              }
            }

            peer.isConnected = true;

            final supportedFeatures = u.unpackInt();

            if (supportedFeatures != 3) {
              throw 'Remote node does not support required features';
            }

            peers[peer.id] = peer;
            reconnectDelay[peer.id] = 1;

            final connectionUrisCount = u.unpackInt()!;

            peer.connectionUris.clear();
            for (int i = 0; i < connectionUrisCount; i++) {
              peer.connectionUris.add(Uri.parse(u.unpackString()!));
            }

            logger.info(
              '${'[+]'.green().bold()} ${peer.id.toString().green()} (${(peer.renderLocationUri()).toString().cyan()})',
            );

            sendPublicPeersToPeer(peer, peers.values);
            for (final p in peers.values) {
              if (p.id == peer.id) continue;

              if (p.isConnected) {
                sendPublicPeersToPeer(p, [peer]);
              }
            }

            return;
            /* } else if (method2 == protocolMethodHashQueryResponse) { */
          } else if (method2 == protocolMethodAnnouncePeers) {
            final length = u.unpackInt()!;
            for (int i = 0; i < length; i++) {
              final peerIdBinary = u.unpackBinary();
              final id = NodeID(peerIdBinary);

              final isConnected = u.unpackBool()!;

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
          final hash = Multihash(u.unpackBinary());
          final types = u.unpackList().cast<int>();

          try {
            final map = node.getCachedStorageLocations(hash, types);

            if (map.isNotEmpty) {
              final availableNodes = map.keys.toList();
              sortNodesByScore(availableNodes);

              final entry = map[availableNodes.first]!;

              peer.sendMessage(entry.providerMessage);

              return;
            }
          } catch (e, st) {
            logger.catched(e, st);
          }

          final contains = node.exposeStore &&
              await node.store!.canProvide(
                hash,
                types,
              );

          if (contains) {
            final location = await node.store!.provide(hash, types);

            final message = await prepareProvideMessage(hash, location);

            node.addStorageLocation(
              hash,
              localNodeId,
              location,
              message: message,
            );

            logger.verbose('[providing] $hash');

            peer.sendMessage(message);
            return;
          }

          if (hashQueryRoutingTable.containsKey(hash)) {
            if (!hashQueryRoutingTable[hash]!.contains(peer.id)) {
              hashQueryRoutingTable[hash]!.add(peer.id);
            }
          } else {
            hashQueryRoutingTable[hash] = <NodeID>{peer.id};
            for (final p in peers.values) {
              if (p.id != peer.id) {
                p.sendMessage(event);
              }
            }
          }

          return;
        } else if (method == protocolMethodRegistryQuery) {
          final pk = u.unpackBinary();
          final sre = node.registry.getFromDB(pk);
          if (sre != null) {
            peer.sendMessage(node.registry.serializeRegistryEntry(sre));
          }
        }
      },
      onDone: () async {
        try {
          if (peers.containsKey(peer.id)) {
            peers.remove(peer.id);
            logger.info(
              '${'[-]'.red().bold()} ${peer.id.toString().red()} (${(peer.renderLocationUri()).toString().cyan()})',
            );
          }
        } catch (_) {
          logger.info('[-] ${peer.renderLocationUri()}');
        }
        completer.completeError('onDone');
      },
      onError: (e) {
        logger.warn('${peer.id}: $e');
      },
      logger: logger,
    );
    peer.sendMessage(initialAuthPayloadPacker.takeBytes());

    return completer.future;
  }

  Future<Uint8List> prepareProvideMessage(
      Multihash hash, StorageLocation location) async {
    final list = [recordTypeStorageLocation] +
        hash.fullBytes +
        [location.type] +
        encodeEndian(location.expiry, 4) +
        [location.parts.length];

    for (final part in location.parts) {
      final bytes = utf8.encode(part);
      list.addAll(encodeEndian(bytes.length, 2));
      list.addAll(bytes);
    }
    list.add(0);

    final signature = await node.crypto.signEd25519(
      kp: nodeKeyPair,
      message: Uint8List.fromList(list),
    );

    return Uint8List.fromList(list + nodeKeyPair.publicKey + signature);
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
    peer.sendMessage(await signMessageSimple(p.takeBytes()));
  }

  // TODO nodes with a score below 0.2 should be disconnected immediately and responses dropped

  double getNodeScore(NodeID nodeId) {
    if (nodeId == localNodeId) {
      return 1;
    }
    final node = nodesBox.get(nodeId.bytes);
    if (node == null) {
      return 0.5;
    }
    final map = Unpacker(node).unpackMap().cast<int, int>();
    return calculateScore(map[1]!, map[2]!);
  }

  void _vote(NodeID nodeId, bool upvote) {
    final node = nodesBox.get(nodeId.bytes);
    final map = node == null
        ? <int, int>{1: 0, 2: 0}
        : Unpacker(node).unpackMap().cast<int, int>();

    if (upvote) {
      map[1] = map[1]! + 1;
    } else {
      map[2] = map[2]! + 1;
    }

    nodesBox.set(
      nodeId.bytes,
      (Packer()..pack(map)).takeBytes(),
    );
  }

  void upvote(NodeID nodeId) {
    _vote(nodeId, true);
  }

  void downvote(NodeID nodeId) {
    _vote(nodeId, false);
  }

  // TODO add a bit of randomness with multiple options
  void sortNodesByScore(List<NodeID> nodes) {
    nodes.sort(
      (a, b) {
        return -getNodeScore(a).compareTo(getNodeScore(b));
      },
    );
  }

  // TODO Only used for the handshake, should be removed as soon as QUIC+TLS or WSS is used
  Future<Uint8List> signMessageSimple(Uint8List message) async {
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
    final nodeId = NodeID(u.unpackBinary());
    final signature = u.unpackBinary();
    final message = u.unpackBinary();

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

  void sendHashRequest(Multihash hash,
      [List<int> types = const [storageLocationTypeFull]]) {
    final p = Packer();

    p.packInt(protocolMethodHashQuery);
    p.packBinary(hash.fullBytes);
    p.pack(types);
    // TODO Maybe add int for hop count (or not because privacy concerns)

    final req = p.takeBytes();

    for (final peer in peers.values) {
      peer.sendMessage(req);
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

    reconnectDelay[id] = reconnectDelay[id] ?? 1;

    final ip = connectionUri.host;
    final port = connectionUri.port;

    if (id == localNodeId) {
      return;
    }
    bool retried = false;
    runZonedGuarded(
      () async {
        logger.verbose('[connect] $connectionUri');

        final socket = await Socket.connect(ip, port);

        await onNewPeer(
          Peer(
            socket,
            connectionUris: [connectionUri],
          )..id = id,
          verifyId: true,
        );
      },
      (e, st) async {
        if (retried) return;
        retried = true;

        if (e is SocketException) {
          if (e.message == 'Connection refused') {
            logger.warn('[!] $id: $e');
          } else {
            logger.catched(e, st);
          }
        } else {
          logger.catched(e, st);
        }

        final delay = reconnectDelay[id]!;
        reconnectDelay[id] = delay * 2;
        await Future.delayed(Duration(seconds: delay));

        connectToNode(connectionUris);
      },
    );
  }
}
