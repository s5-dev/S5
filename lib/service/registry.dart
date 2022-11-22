import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/registry.dart';
import 'package:lib5/util.dart';
import 'package:messagepack/messagepack.dart';

import 'package:s5_server/node.dart';
import 'package:s5_server/service/p2p.dart';

class RegistryService {
  late final Box<Uint8List> db;
  final S5Node node;

  RegistryService(this.node);

  Future<void> init() async {
    db = await Hive.openBox('s5-registry-db');
  }

  Future<void> set(
    SignedRegistryEntry sre, {
    bool trusted = false,
    Peer? receivedFrom,
  }) async {
    node.logger.verbose(
      '[registry] set ${base64Url.encode(sre.pk)} ${sre.revision} (${receivedFrom?.id})',
    );

    if (!trusted) {
      if (sre.pk.length != 33) {
        throw 'Invalid pubkey';
      }
      if (sre.pk[0] != mkeyEd25519) {
        throw 'Only ed25519 keys are supported';
      }
      if (sre.revision < 0 || sre.revision > 281474976710656) {
        throw 'Invalid revision';
      }
      if (sre.data.length > registryMaxDataSize) {
        throw 'Data too long';
      }
      final isValid = await verifyRegistryEntry(
        sre,
        crypto: node.crypto,
      );

      if (!isValid) {
        throw 'Invalid signature found';
      }
    }

    final existingEntry = getFromDB(sre.pk);
    if (existingEntry != null) {
      if (existingEntry.revision >= sre.revision) {
        // TODO broadcastEntry(existingEntry, null);

        throw 'Revision number too low';
      }
    }
    final key = String.fromCharCodes(sre.pk);

    streams[key]?.add(sre);

    final packer = Packer();

    packer.packBinary(sre.data);
    packer.packInt(sre.revision);
    packer.packBinary(sre.signature);

    await db.put(key, packer.takeBytes());

    if (existingEntry != null) {
      if (!areBytesEqual(existingEntry.data, sre.data)) {
        // TODO First check if this hash is actually not referenced from other locations
        // could cause data loss or be used for an attack
        final bytes = existingEntry.data;
        node.deleteHash(Multihash(bytes.sublist(2)));
      }
    }

    broadcastEntry(sre, receivedFrom);
  }

  // TODO Clean this table after some time
  // TODO final registryUpdateRoutingTable = <String, List<String>>{};

  // TODO Only broadcast to subscribed nodes (routing table) and shard-nodes (256)
  void broadcastEntry(SignedRegistryEntry sre, Peer? receivedFrom) {
    node.logger.verbose('[registry] broadcastEntry');
    final updateMessage = prepareMessage(sre);

    for (final p in node.p2p.peers.values) {
      if (receivedFrom == null) {
        p.socket.add(updateMessage);
      } else {
        if (p.id != receivedFrom.id &&
            !receivedFrom.connectedPeers.contains(p.id)) {
          p.socket.add(updateMessage);
        }
      }
    }
  }

  void sendRegistryRequest(Uint8List pk) {
    final p = Packer();

    p.packInt(protocolMethodRegistryQuery);
    p.packBinary(pk);

    final req = p.takeBytes();

    // TODO Use shard system

    for (final peer in node.p2p.peers.values) {
      peer.socket.add(req);
    }
  }

  Uint8List prepareMessage(SignedRegistryEntry sre) {
    final p = Packer();
    p.packInt(protocolMethodRegistryUpdate);

    p.packBinary(sre.pk);
    p.packInt(sre.revision);
    p.packBinary(sre.data);
    p.packBinary(sre.signature);

    return p.takeBytes();
  }

  final streams = <String, StreamController<SignedRegistryEntry>>{};

  Future<SignedRegistryEntry?> get(Uint8List pk) async {
    node.logger.verbose(
      '[registry] get ${base64Url.encode(pk)}',
    );

    final res = getFromDB(pk);

    if (res != null) {
      return res;
    }
    sendRegistryRequest(pk);
    return null;
    // TODO Improve to wait a bit if not already subbed
  }

  Stream<SignedRegistryEntry> listen(Uint8List pk) {
    final key = String.fromCharCodes(pk);
    if (!streams.containsKey(key)) {
      streams[key] = StreamController<SignedRegistryEntry>.broadcast();
    }
    return streams[key]!.stream;
  }

  SignedRegistryEntry? getFromDB(Uint8List pk) {
    final key = String.fromCharCodes(pk);
    if (db.containsKey(key)) {
      final u = Unpacker(db.get(key)!);
      return SignedRegistryEntry(
        pk: pk,
        data: Uint8List.fromList(u.unpackBinary()),
        revision: u.unpackInt()!,
        signature: Uint8List.fromList(u.unpackBinary()),
      );
    }
    return null;
  }

  Future<void> setEntryHelper(
    KeyPairEd25519 keyPair,
    Uint8List data,
  ) async {
    final revision = (DateTime.now().millisecondsSinceEpoch / 1000).round();

    final sre = await signRegistryEntry(
      kp: keyPair,
      data: data,
      revision: revision,
      crypto: node.crypto,
    );

    set(sre);
  }
}
