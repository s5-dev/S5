import 'package:s5_server/model/multihash.dart';
import 'package:s5_server/node.dart';

class DownloadUriProvider {
  final S5Node node;
  final Multihash hash;

  DownloadUriProvider(this.node, this.hash);

  final timeoutDuration = Duration(seconds: 60);

  List<String> availableNodes = [];
  late final Map<String, Uri> uris;

  bool isTimedOut = false;

  void start() async {
    uris = node.getDownloadUrisFromDB(hash);
    if (!uris.containsKey(node.p2p.localNodeId)) {
      await node.fetchHashLocally(hash);
    }
    availableNodes = uris.keys.toList();
    node.p2p.sortNodesByScore(availableNodes);

    final timeout = DateTime.now().add(timeoutDuration);

    _waitUntilIsWaiting(); // TODO This could run forever

    node.p2p.sendHashRequest(hash);

    while (true) {
      final newUris = node.getDownloadUrisFromDB(hash);
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
    }
  }

  Future<void> _waitUntilIsWaiting() async {
    while (isWaitingForUri == false) {
      await Future.delayed(Duration(milliseconds: 1));
    }
  }

  bool isWaitingForUri = false;

  Future<DownloadURI> next() async {
    while (true) {
      if (availableNodes.isNotEmpty) {
        isWaitingForUri = false;
        final nodeId = availableNodes.removeAt(0);

        return DownloadURI(nodeId, uris[nodeId]!);
      }
      isWaitingForUri = true;
      if (isTimedOut) {
        throw 'Could not download raw file: Timed out after $timeoutDuration';
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
  final String nodeId;
  final Uri uri;
  DownloadURI(this.nodeId, this.uri);
}
