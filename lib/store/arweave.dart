/* import 'dart:convert';
import 'dart:typed_data';

import 'package:arweave/arweave.dart';
import 'package:arweave/utils.dart';
import 'package:http/http.dart';
import 'package:lib5/lib5.dart';

import 'base.dart';

const publicGateways = [
  'https://arweave.net',
  'https://arweave.dev',
  'https://node1.bundlr.network',
  'https://node2.bundlr.network',
  'https://gateway.redstone.finance',
];

class ArweaveObjectStore extends ObjectStore {
  final Arweave client;
  final Wallet wallet;
  final httpClient = Client();

  ArweaveObjectStore(this.client, this.wallet);

  @override
  final canPutAsync = false;

  @override
  Future<bool> contains(Multihash hash) async {
    print(transactionHashCache);
    final res = await getTransactionIdForHash(hash);
    return res != null;
  }

  @override
  Future<void> put(
    Multihash hash,
    Stream<Uint8List> data,
    int length,
  ) async {
    if (await contains(hash)) {
      return;
    }
    print('put');

    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }

    final transaction = await client.transactions.prepare(
      Transaction.withBlobData(
        data: Uint8List.fromList(bytes),
      ),
      wallet,
    );
    transaction.tags.add(
      Tag(
        encodeStringToBase64('Multihash'),
        encodeStringToBase64(hash.toBase64Url()),
      ),
    );

    transaction.addTag('User-Agent', 's5-dart');

    // TODO Maybe add "Content-Type"
    // TODO Maybe add "User-Agent-Version"

    await transaction.sign(wallet);

    await for (final upload in client.transactions.upload(transaction)) {
      // TODO progress updates
    }

    transactionHashCache[hash] = transaction.id;
  }

  @override
  Future<String> provide(Multihash hash) async {
    final id = await getTransactionIdForHash(hash);
    return client.api.gatewayUrl.resolve(id!).toString();
  }

  final transactionHashCache = <Multihash, String>{};

  Future<String?> getTransactionIdForHash(Multihash hash) async {
    if (transactionHashCache.containsKey(hash)) {
      return transactionHashCache[hash]!;
    }
    final res = await queryForHash(hash);
    if (res.isEmpty) {
      return null;
    }

    // TODO Sort by timestamp
    // TODO Check size
    // TODO Check owner address (opt-in, only use own address by default)

    final id = res.first['node']['id'];
    transactionHashCache[hash] = id;
    return id;
  }

  Future<List<Map>> queryForHash(Multihash hash) async {
    final query = '''query {
    transactions(
        tags: {
            name: "Multihash",
            values: ["${hash.toBase64Url()}"]
				},
				first: 16
    ) {
        edges {
            node {
                id
								owner {
									address
								}
                data {
                    size
                    type
                }
                tags {
                    name
                    value
                }
              	block {
                	timestamp
              	}
            }
        }
    }
}''';
    final res = await httpClient.post(
      client.api.gatewayUrl.resolve(
        '/graphql',
      ),
      headers: {
        'Content-Type': 'application/json',
      },
      body: json.encode({'query': query}),
    );
    if (res.statusCode != 200) {
      throw 'HTTP ${res.statusCode}: ${res.body}';
    }

    return json.decode(res.body)['data']['transactions']['edges'].cast<Map>();
  }

  @override
  Future<void> delete(Multihash hash) {
    throw 'Arweave files can never be deleted';
  }
}
 */