import 'dart:async';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/registry.dart';
import 'package:lib5/util.dart';
import 'package:s5_msgpack/s5_msgpack.dart';
import 'package:s5_server/db/hive_key_value_db.dart';

import 'package:s5_server/node.dart';
import 'package:s5_server/service/p2p.dart';

class RegistryService {
  late final HiveKeyValueDB db;
  final S5Node node;

  RegistryService(this.node);

  Future<void> init() async {
    db = HiveKeyValueDB(await Hive.openBox('s5-registry-db'));
  }

  Future<void> set(
    SignedRegistryEntry sre, {
    bool trusted = false,
    Peer? receivedFrom,
  }) async {
    node.logger.verbose(
      '[registry] set ${base64UrlNoPaddingEncode(sre.pk)} ${sre.revision} (${receivedFrom?.id})',
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
          final updateMessage = serializeRegistryEntry(existingEntry);
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

    db.set(sre.pk, serializeRegistryEntry(sre));

    broadcastEntry(sre, receivedFrom);
  }

  // TODO Clean this table after some time
  // TODO final registryUpdateRoutingTable = <String, List<String>>{};
  // TODO if there are more than X peers, only broadcast to subscribed nodes (routing table) and shard-nodes (256)
  void broadcastEntry(SignedRegistryEntry sre, Peer? receivedFrom) {
    node.logger.verbose('[registry] broadcastEntry');
    final updateMessage = serializeRegistryEntry(sre);

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
    if (db.contains(pk)) {
      return deserializeRegistryEntry(db.get(pk)!);
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

  Uint8List serializeRegistryEntry(SignedRegistryEntry sre) {
    return Uint8List.fromList([
      recordTypeRegistryEntry,
      ...sre.pk,
      ...encodeEndian(sre.revision, 8),
      sre.data.length,
      ...sre.data,
      ...sre.signature,
    ]);
  }

  SignedRegistryEntry deserializeRegistryEntry(Uint8List event) {
    final dataLength = event[42];
    return SignedRegistryEntry(
      pk: event.sublist(1, 34),
      revision: decodeEndian(event.sublist(34, 42)),
      data: event.sublist(43, 43 + dataLength),
      signature: event.sublist(43 + dataLength),
    );
  }
}
