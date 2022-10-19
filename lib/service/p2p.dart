import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart';
import 'package:hive/hive.dart';
import 'package:messagepack/messagepack.dart';
import 'package:s5_server/constants.dart';
import 'package:s5_server/crypto/ed25519.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/model/multihash.dart';
import 'package:s5_server/model/signed_message.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/registry/registry.dart';
import 'package:s5_server/util/bytes.dart';
import 'package:s5_server/util/score.dart';
import 'package:tint/tint.dart';

class Peer {
  // TODO Always store id as Uint8List
  late final String id;
  late final Uint8List binaryId;

  final Socket socket;
  final List<Uri> connectionUris;

  bool isConnected = false;

  final connectedPeers = <String>{};

  final challenge = Uint8List(32);

  Peer(
    this.socket, {
    required this.connectionUris,
  });
}

class P2PService {
  final S5Node node;

  late KeyPair nodeKeyPair;

  P2PService(this.node);

  Logger get logger => node.logger;

  late final Box<Map> nodesBox;

  late final Uint8List nodeIdBinary;

  late final String localNodeId;

  final peers = <String, Peer>{};

  final List<Uri> selfConnectionUris = [];
  final reconnectDelay = <String, int>{};

  // TODO clean this table after a while (default 1 hour)
  final hashQueryRoutingTable = <String, List<String>>{};

  Future<void> init() async {
    nodeIdBinary = Uint8List.fromList(
      [mkeyEd25519] +
          (await nodeKeyPair.extractPublicKey() as SimplePublicKey).bytes,
    );

    localNodeId = encodeNodeId(
      nodeIdBinary,
    );
    nodesBox = await Hive.openBox('nodes');
  }

  Future<void> start() async {
    final networkSelf = node.config['network']?['self'];

    if (networkSelf != null) {
      final socket = await ServerSocket.bind('0.0.0.0', networkSelf['port']);
      socket.listen((peerSocket) {
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
      });
      selfConnectionUris.add(
        Uri.parse('tcp://${networkSelf['ip']}:${networkSelf['port']}'),
      );

      logger.info('connection uris: $selfConnectionUris');
    }
    final initialPeers = node.config['network']?['peers']?['initial'] ?? [];

    for (final p in initialPeers) {
      connectToNode([Uri.parse(p)]);
    }
  }

  void onNewPeer(Peer peer, Function? reconnect) {
    fillBytesWithSecureRandom(peer.challenge);

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
          for (final u in selfConnectionUris) {
            p.packString(u.toString());
          }
          peer.socket.add(await signMessage(p.takeBytes()));
          return;
        } else if (method == protocolMethodRegistryUpdate) {
          final sre = SignedRegistryEntry(
            pk: Uint8List.fromList(u.unpackBinary()),
            dk: Uint8List.fromList(u.unpackBinary()),
            data: Uint8List.fromList(u.unpackBinary()),
            revision: u.unpackInt()!,
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

            if (!equal(peer.challenge, challenge)) {
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
            peer.binaryId = decodeNodeId(pId);

            peer.isConnected = true;

            peers[peer.id] = peer;
            reconnectDelay[peer.id] = 1;
            final connectionUrisCount = u.unpackInt()!;

            peer.connectionUris.clear();
            for (int i = 0; i < connectionUrisCount; i++) {
              peer.connectionUris.add(Uri.parse(u.unpackString()!));
            }

            logger.info(
              '${'[+]'.green().bold()} ${peer.id.green()} (${(peer.connectionUris.isEmpty ? peer.socket.address.address : peer.connectionUris.first).toString().cyan()})',
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

            final list = hashQueryRoutingTable[hash.key] ?? [];
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
              final id = encodeNodeId(Uint8List.fromList(peerIdBinary));

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
                final uri = connectionUris.first.replace(userInfo: id);
                if (!reconnectDelay.containsKey(uri.userInfo)) {
                  connectToNode([uri]);
                }
              }
            }
          }
        } else if (method == protocolMethodHashQuery) {
          final hash = Multihash(Uint8List.fromList(u.unpackBinary()));

          final contains = node.exposeStore && await node.store!.contains(hash);
          if (!contains) {
            hashQueryRoutingTable[hash.key] =
                (hashQueryRoutingTable[hash.key] ?? []) + [peer.id];

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
          p.packBinary(hash.bytes);
          p.packInt(
            DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
          );
          p.packString(result);

          peer.socket.add(await signMessage(p.takeBytes()));
        } else if (method == protocolMethodRegistryQuery) {
          final pk = Uint8List.fromList(u.unpackBinary());
          final dk = Uint8List.fromList(u.unpackBinary());
          final sre = node.registry.getFromDB(pk, dk);
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
              '${'[-]'.red().bold()} ${peer.id.red()} (${(peer.connectionUris.isEmpty ? peer.socket.address.address : peer.connectionUris.first).toString().cyan()})',
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
      p.packBinary(pts.binaryId);
      p.packBool(pts.isConnected);
      p.packInt(pts.connectionUris.length);
      for (final u in pts.connectionUris) {
        p.packString(u.toString());
      }
    }
    peer.socket.add(await signMessage(p.takeBytes()));
  }

  double getNodeScore(String nodeId) {
    if (nodeId == localNodeId) {
      return 1;
    }
    final p = nodesBox.get(nodeId) ?? {};
    return calculateScore(p['+'] ?? 0, p['-'] ?? 0);
  }

  void incrementScoreCounter(String nodeId, String type) {
    final p = nodesBox.get(nodeId) ?? {};
    p[type] = (p[type] ?? 0) + 1;

    nodesBox.put(nodeId, p);
  }

  // TODO add a bit of randomness with multiple options
  void sortNodesByScore(List<String> nodes) {
    nodes.sort(
      (a, b) {
        return -getNodeScore(a).compareTo(getNodeScore(b));
      },
    );
  }

  String encodeNodeId(Uint8List bytes) {
    return 'z${base58Bitcoin.encode(bytes)}';
  }

  Uint8List decodeNodeId(String str) {
    return base58Bitcoin.decode(str.substring(1));
  }

  Future<Uint8List> signMessage(Uint8List message) async {
    final packer = Packer();

    final signature = await ed25519.sign(message, keyPair: nodeKeyPair);

    packer.packInt(protocolMethodSignedMessage);
    packer.packBinary(nodeIdBinary);

    packer.packBinary(signature.bytes);
    packer.packBinary(message);

    return packer.takeBytes();
  }

  Future<SignedMessage> unpackAndVerifySignature(Unpacker u) async {
    final nodeId = u.unpackBinary();

    final signature = u.unpackBinary();

    final message = u.unpackBinary();
    final isValid = await ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          nodeId.sublist(1),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!isValid) {
      throw 'Invalid signature found';
    }
    return SignedMessage(
      nodeId: encodeNodeId(Uint8List.fromList(nodeId)),
      message: Uint8List.fromList(message),
    );
  }

  void sendHashRequest(Multihash hash) {
    final p = Packer();

    p.packInt(protocolMethodHashQuery);
    p.packBinary(hash.bytes);

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
    final id = connectionUri.userInfo;
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
