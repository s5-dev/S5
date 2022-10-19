import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive/hive.dart';
import 'package:messagepack/messagepack.dart';
import 'package:s5_server/constants.dart';
import 'package:s5_server/crypto/ed25519.dart';
import 'package:s5_server/model/multihash.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/service/p2p.dart';
import 'package:s5_server/util/bytes.dart';

import 'encode_endian/base.dart';
import 'encode_endian/encode_endian.dart';

class RegistryService {
  late final Box<Uint8List> db;
  final S5Node node;

  RegistryService(this.node);

  Future<void> init() async {
    db = await Hive.openBox('registry');
  }

  Future<void> set(
    SignedRegistryEntry sre, {
    bool trusted = false,
    Peer? receivedFrom,
  }) async {
    node.logger.verbose(
      '[registry] set ${base64Url.encode(sre.pk)} ${base64Url.encode(sre.dk)} ${sre.revision} (${receivedFrom?.id})',
    );

    if (!trusted) {
      if (sre.pk.length != 33) {
        throw 'Invalid pubkey';
      }
      if (sre.pk[0] != mkeyEd25519) {
        throw 'Only ed25519 keys are supported';
      }
      if (sre.dk.length != 32) {
        throw 'Invalid datakey';
      }
      if (sre.revision < 0 || sre.revision > 4294967296) {
        throw 'Invalid revision';
      }
      if (sre.data.length > registryMaxDataSize) {
        throw 'Data too long';
      }
      final list = Uint8List.fromList([
        ...sre.dk, // 32 bytes
        ...withPadding(sre.revision), // 8 bytes, little-endian
        sre.data.length, // 1 byte
        ...sre.data,
      ]);

      final isValid = await ed25519.verify(
        list,
        signature: Signature(
          sre.signature,
          publicKey: SimplePublicKey(
            sre.pk.sublist(1),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!isValid) {
        throw 'Invalid signature found';
      }
    }

    final existingEntry = getFromDB(sre.pk, sre.dk);
    if (existingEntry != null) {
      if (existingEntry.revision >= sre.revision) {
        broadcastEntry(existingEntry, null);

        throw 'Revision number too low';
      }
    }
    final key = String.fromCharCodes(sre.pk + sre.dk);

    streams[key]?.add(sre);

    final packer = Packer();

    packer.packBinary(sre.data);
    packer.packInt(sre.revision);
    packer.packBinary(sre.signature);

    await db.put(key, packer.takeBytes());

    if (existingEntry != null) {
      if (!equal(existingEntry.data, sre.data)) {
        // TODO First check if this hash is actually not referenced from other locations
        // could cause data loss or be used for an attack
        node.deleteHash(Multihash(existingEntry.data.sublist(2)));
      }
    }

    broadcastEntry(sre, receivedFrom);
  }

  // TODO Clean this table after some time
  final registryUpdateRoutingTable = <String, List<String>>{};

  // TODO Only broadcast to subscribed nodes (routing table) and shard-nodes (256)
  void broadcastEntry(SignedRegistryEntry sre, Peer? receivedFrom) {
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

  void sendRegistryRequest(Uint8List pk, Uint8List dk) {
    final p = Packer();

    p.packInt(protocolMethodRegistryQuery);
    p.packBinary(pk);
    p.packBinary(dk);

    final req = p.takeBytes();

    // TODO Use shard system
    for (final peer in node.p2p.peers.values) {
      // print('getHttpUrlForHash >peer $hash');
      peer.socket.add(req);
    }
  }

  Uint8List prepareMessage(SignedRegistryEntry sre) {
    final p = Packer();
    p.packInt(protocolMethodRegistryUpdate);

    p.packBinary(sre.pk);
    p.packBinary(sre.dk);

    p.packBinary(sre.data);
    p.packInt(sre.revision);
    p.packBinary(sre.signature);

    return p.takeBytes();
  }

  final streams = <String, StreamController<SignedRegistryEntry>>{};

  Future<SignedRegistryEntry?> get(Uint8List pk, Uint8List dk) async {
    final res = getFromDB(pk, dk);

    if (res != null) {
      return res;
    }
    sendRegistryRequest(pk, dk);
    return null;
    // TODO Improve to wait a bit if not already subbed
  }

  Stream<SignedRegistryEntry> listen(Uint8List pk, Uint8List dk) {
    final key = String.fromCharCodes(pk + dk);
    if (!streams.containsKey(key)) {
      streams[key] = StreamController<SignedRegistryEntry>.broadcast();
    }
    return streams[key]!.stream;
  }

  SignedRegistryEntry? getFromDB(Uint8List pk, Uint8List dk) {
    final key = String.fromCharCodes(pk + dk);
    if (db.containsKey(key)) {
      final u = Unpacker(db.get(key)!);
      return SignedRegistryEntry(
        pk: pk,
        dk: dk,
        data: Uint8List.fromList(u.unpackBinary()),
        revision: u.unpackInt()!,
        signature: Uint8List.fromList(u.unpackBinary()),
      );
    }
    return null;
  }

  Future<void> setEntryHelper(
    KeyPair keyPair,
    Uint8List pk,
    Uint8List dk,
    Uint8List data,
  ) async {
    final revision = (DateTime.now().millisecondsSinceEpoch / 1000).round();

    final list = Uint8List.fromList([
      ...dk, // 32 bytes
      ...withPadding(revision), // 8 bytes, little-endian
      data.length, // 1 byte
      ...data,
    ]);

    final signature = await ed25519.sign(list, keyPair: keyPair);

    final sre = SignedRegistryEntry(
      pk: pk,
      dk: dk,
      revision: revision,
      data: data,
      signature: Uint8List.fromList(signature.bytes),
    );
    set(sre);
  }
}

List<int> withPadding(int i) {
  return encodeEndian(i, 8, endianType: EndianType.littleEndian) as List<int>;
}

class SignedRegistryEntry {
  final Uint8List pk;
  final Uint8List dk;
  final int revision;
  final Uint8List data;
  final Uint8List signature;

  SignedRegistryEntry({
    required this.pk,
    required this.dk,
    required this.revision,
    required this.data,
    required this.signature,
  });
}
