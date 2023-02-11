import 'package:lib5/lib5.dart';
import 'package:lib5/constants.dart';

import 'package:s5_server/model/node_id.dart';
import 'package:s5_server/node.dart';

class DownloadUriProvider {
  final S5Node node;
  final Multihash hash;

  DownloadUriProvider(this.node, this.hash);

  final timeoutDuration = Duration(seconds: 60);

  List<NodeID> availableNodes = [];
  late final Map<NodeID, Uri> uris;

  late DateTime timeout;

  bool isTimedOut = false;

  void start() async {
    uris = node.getDownloadUrisFromDB(hash);

    availableNodes = uris.keys.toList();
    node.p2p.sortNodesByScore(availableNodes);

    if (uris.isEmpty) {
      await node.fetchHashLocally(hash);
    }

    timeout = DateTime.now().add(timeoutDuration);

    bool requestSent = false;

    while (true) {
      final newUris = node.getDownloadUrisFromDB(hash);

      if (availableNodes.isEmpty && newUris.isEmpty && !requestSent) {
        node.p2p.sendHashRequest(hash);
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

  Future<DownloadURI> next() async {
    timeout = DateTime.now().add(timeoutDuration);
    while (true) {
      if (availableNodes.isNotEmpty) {
        isWaitingForUri = false;
        final nodeId = availableNodes.removeAt(0);

        return DownloadURI(nodeId, uris[nodeId]!);
      }
      isWaitingForUri = true;
      if (isTimedOut) {
        throw 'Could not download raw file: Timed out after $timeoutDuration ${hash.toBase64Url()}';
      }
      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  void upvote(DownloadURI uri) {
    node.p2p.incrementScoreCounter(uri.nodeId, '+');
  }

  void downvote(DownloadURI uri) {
    node.p2p.incrementScoreCounter(uri.nodeId, '-');
  }
}

class DownloadURI {
  final NodeID nodeId;
  final Uri uri;
  // TODO Support custom headers

  DownloadURI(this.nodeId, this.uri);

  @override
  toString() => 'DownloadURI($uri, $nodeId)';
}
