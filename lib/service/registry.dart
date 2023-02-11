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
      if (receivedFrom != null) {
        if (existingEntry.revision == sre.revision) {
          return;
        } else if (existingEntry.revision > sre.revision) {
          final updateMessage = prepareMessage(existingEntry);
          receivedFrom.sendMessage(updateMessage);
          return;
        }
      }

      if (existingEntry.revision >= sre.revision) {
        throw 'Revision number too low';
      }
    }
    final key = Multihash(sre.pk);

    streams[key]?.add(sre);

    final packer = Packer();

    packer.packBinary(sre.data);
    packer.packInt(sre.revision);
    packer.packBinary(sre.signature);

    await db.put(key, packer.takeBytes());

    broadcastEntry(sre, receivedFrom);
  }

  // TODO Clean this table after some time
  // TODO final registryUpdateRoutingTable = <String, List<String>>{};
  // TODO if there are more than X peers, only broadcast to subscribed nodes (routing table) and shard-nodes (256)
  void broadcastEntry(SignedRegistryEntry sre, Peer? receivedFrom) {
    node.logger.verbose('[registry] broadcastEntry');
    final updateMessage = prepareMessage(sre);

    for (final p in node.p2p.peers.values) {
      if (receivedFrom == null || p.id != receivedFrom.id) {
        p.sendMessage(updateMessage);
      }
    }
  }

  void sendRegistryRequest(Uint8List pk) {
    final p = Packer();

    p.packInt(protocolMethodRegistryQuery);
    p.packBinary(pk);

    final req = p.takeBytes();

    // TODO Use shard system if there are more than X peers

    for (final peer in node.p2p.peers.values) {
      peer.sendMessage(req);
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

  final streams = <Multihash, StreamController<SignedRegistryEntry>>{};

  Future<SignedRegistryEntry?> get(Uint8List pk) async {
    final key = Multihash(pk);
    if (streams.containsKey(key)) {
      node.logger.verbose('[registry] get (subbed) $key');
      final res = getFromDB(pk);
      if (res != null) {
        return res;
      }
      sendRegistryRequest(pk);
      await Future.delayed(Duration(milliseconds: 200));
      return getFromDB(pk);
    } else {
      sendRegistryRequest(pk);
      streams[key] = StreamController<SignedRegistryEntry>.broadcast();
      if (getFromDB(pk) == null) {
        node.logger.verbose('[registry] get (clean) $key');
        for (int i = 0; i < 200; i++) {
          await Future.delayed(Duration(milliseconds: 10));
          if (getFromDB(pk) != null) break;
        }
      } else {
        node.logger.verbose('[registry] get (cached) $key');
        await Future.delayed(Duration(milliseconds: 200));
      }
      return getFromDB(pk);
    }
  }

  Stream<SignedRegistryEntry> listen(Uint8List pk) {
    final key = Multihash(pk);
    if (!streams.containsKey(key)) {
      streams[key] = StreamController<SignedRegistryEntry>.broadcast();
      sendRegistryRequest(pk);
    }
    return streams[key]!.stream;
  }

  SignedRegistryEntry? getFromDB(Uint8List pk) {
    final key = Multihash(pk);
    if (db.containsKey(key)) {
      final u = Unpacker(db.get(key)!);
      return SignedRegistryEntry(
        pk: pk,
        data: u.unpackBinary(),
        revision: u.unpackInt()!,
        signature: u.unpackBinary(),
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
