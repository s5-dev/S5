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
          node.p2p.nodeKeyPair.extractBytes() + encodeEndian(32, 32),
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

    app.post('/s5/admin/accounts', (req, res) async {
      checkAuth(req);
      final id =
          await node.accounts!.createAccount(req.uri.queryParameters['email']!);
      return {'id': id};
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
