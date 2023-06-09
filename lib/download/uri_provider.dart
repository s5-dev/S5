import 'package:lib5/lib5.dart';
import 'package:lib5/constants.dart';

import 'package:s5_server/node.dart';

class StorageLocationProvider {
  final S5Node node;
  final Multihash hash;
  final List<int> types;

  StorageLocationProvider(
    this.node,
    this.hash, [
    this.types = const [storageLocationTypeFull],
  ]);

  final timeoutDuration = Duration(seconds: 60);

  List<NodeID> availableNodes = [];
  late final Map<NodeID, StorageLocation> uris;

  late DateTime timeout;

  bool isTimedOut = false;

  void start() async {
    uris = node.getCachedStorageLocations(hash, types);

    availableNodes = uris.keys.toList();
    node.p2p.sortNodesByScore(availableNodes);

    if (uris.isEmpty) {
      await node.fetchHashLocally(hash, types);
    }

    timeout = DateTime.now().add(timeoutDuration);

    bool requestSent = false;

    while (true) {
      final newUris = node.getCachedStorageLocations(hash, types);

      if (availableNodes.isEmpty && newUris.length < 2 && !requestSent) {
        node.p2p.sendHashRequest(hash, types);
        requestSent = true;
      }
      bool hasNewNode = false;

      for (final e in newUris.entries) {
        if (uris.containsKey(e.key)) {
          if (e.value != uris[e.key]) {
            uris[e.key] = e.value;
            if (!availableNodes.contains(e.key)) {
              availableNodes.add(e.key);
              hasNewNode = true;
            }
          }
        } else {
          uris[e.key] = e.value;
          availableNodes.add(e.key);
          hasNewNode = true;
        }
      }
      if (hasNewNode) {
        node.p2p.sortNodesByScore(availableNodes);
      }
      await Future.delayed(Duration(milliseconds: 10));
      if (DateTime.now().isAfter(timeout)) {
        isTimedOut = true;
        return;
      }
      while (availableNodes.isNotEmpty || !isWaitingForUri) {
        await Future.delayed(Duration(milliseconds: 10));
        if (DateTime.now().isAfter(timeout)) {
          isTimedOut = true;
          return;
        }
      }
    }
  }

  bool isWaitingForUri = false;

  Future<SignedStorageLocation> next() async {
    timeout = DateTime.now().add(timeoutDuration);
    while (true) {
      if (availableNodes.isNotEmpty) {
        isWaitingForUri = false;
        final nodeId = availableNodes.removeAt(0);

        return SignedStorageLocation(nodeId, uris[nodeId]!);
      }
      isWaitingForUri = true;
      if (isTimedOut) {
        throw 'Could not download raw file: Timed out after $timeoutDuration $hash';
      }
      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  void upvote(SignedStorageLocation uri) {
    node.p2p.upvote(uri.nodeId);
  }

  void downvote(SignedStorageLocation uri) {
    node.p2p.downvote(uri.nodeId);
  }
}

class SignedStorageLocation {
  final NodeID nodeId;
  final StorageLocation location;

  // TODO Support custom headers

  SignedStorageLocation(this.nodeId, this.location);

  @override
  toString() => 'SignedStorageLocation($location, $nodeId)';
}
