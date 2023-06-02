import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/util.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/service/accounts.dart';

class AdminAPI {
  // ! /s5/admin

  final S5Node node;

  AdminAPI(this.node);

  void init(Alfred app) async {
    final adminApiKey = base58BitcoinEncode(
      await node.crypto.hashBlake3(
        Uint8List.fromList(
          node.p2p.nodeKeyPair.extractBytes() +
              encodeEndian(
                node.config['http']?['api']?['admin']?['keyRotation'] ?? 0,
                32,
              ),
        ),
      ),
    );

    node.logger.info('');
    node.logger.info('ADMIN API KEY: $adminApiKey');
    node.logger.info('');

    void checkAuth(HttpRequest req) {
      if (req.headers.value('authorization')?.substring(7) != adminApiKey) {
        // req.response.statusCode = 401;
        throw 'Unauthorized';
      }
    }

    app.get('/s5/admin/accounts', (req, res) async {
      checkAuth(req);
      return {
        'accounts': await node.accounts!.getAllAccounts(),
      };
    });

    app.get('/s5/admin/accounts/full', (req, res) async {
      checkAuth(req);
      final res = await node.accounts!.getAllAccounts();
      final accountsFull = <Map>[];
      for (final account in res) {
        final map = account.toJson();
        map['stats'] = await node.accounts!.getStatsForAccount(account.id);
        accountsFull.add(
          map,
        );
      }
      return {
        'accounts': accountsFull,
      };
    });

    app.post('/s5/admin/accounts', (req, res) async {
      checkAuth(req);
      final id =
          await node.accounts!.createAccount(req.uri.queryParameters['email']!);
      return {'id': id};
    });

    app.post('/s5/admin/accounts/set_restricted_status', (req, res) async {
      checkAuth(req);
      await node.accounts!.setRestrictedStatus(
        int.parse(req.uri.queryParameters['id']!),
        req.requestedUri.queryParameters['status'] == 'true',
      );
      return '';
    });

    app.post('/s5/admin/accounts/new_auth_token', (req, res) async {
      checkAuth(req);
      final accountId = int.parse(req.uri.queryParameters['id']!);

      return {
        'auth_token': await node.accounts!.createAuthTokenForAccount(
          accountId,
          'Created using the Admin API',
        ),
      };
    });
  }
}
