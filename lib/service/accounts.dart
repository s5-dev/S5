import 'dart:convert';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:base_codecs/base_codecs.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';

import 'package:s5_server/accounts/account.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/service/sql.dart';
import 'package:s5_msgpack/s5_msgpack.dart';

class AuthResponse {
  final Account? account;
  final bool denied;
  final String? error;

  AuthResponse({
    required this.account,
    required this.denied,
    required this.error,
  });
}

class AccountsService {
  final Map config;
  final Logger logger;
  final CryptoImplementation crypto;

  AccountsService(
    this.config, {
    required this.logger,
    required this.crypto,
  });
  late SQLService sql;

  late final List<String> alwaysAllowedScopes;
  final defaultAlwaysAllowedScopes = [
    'account/login',
    // 'account/register',
    's5/registry/read',
    // 's5/subdomain/load',
    's5/metadata',
    's5/debug/storage_locations',
    's5/debug/download_urls',
    's5/blob/redirect',
  ];

  final tiers = <int, Map>{};

  final defaultTiers = [
    {
      "id": 0,
      "name": "anonymous",
      "uploadBandwidth": 5242880,
      "storageLimit": 0,
    },
    {
      "id": 1,
      "name": "free",
      "uploadBandwidth": 10485760,
      "storageLimit": 10000000000,
      // "scopes": ["test"],
    },
    {
      "id": 2,
      "name": "plus",
      "uploadBandwidth": 20971520,
      "storageLimit": 100000000000
    },
    {
      "id": 3,
      "name": "pro",
      "uploadBandwidth": 41943040,
      "storageLimit": 1000000000000
    },
    {
      "id": 4,
      "name": "extreme",
      "uploadBandwidth": 83886080,
      "storageLimit": 10000000000000
    }
  ];

  late final List<String> authTokensForAccountRegistration;

  Future<AuthResponse> checkAuth(HttpRequest req, String scope) async {
    if (alwaysAllowedScopes.contains(scope)) {
      return AuthResponse(
        account: null,
        denied: false,
        error: null,
      );
    }
    try {
      String? token;
      try {
        token = req.headers.value('authorization')!.substring(7);
      } catch (_) {}

      if (token == null) {
        try {
          token = req.headers
              .value('cookie')!
              .split('s5-auth-token=')[1]
              .split(';')
              .first;
        } catch (_) {}
      }

      if (token == null) {
        try {
          token = req.uri.queryParameters['auth_token'];
        } catch (_) {}
      }

      if (token == null) {
        return AuthResponse(
          account: null,
          denied: true,
          error: 'No auth token found',
        );
      }

      if (scope == 'account/register') {
        if (authTokensForAccountRegistration.contains(token)) {
          return AuthResponse(
            account: null,
            denied: false,
            error: null,
          );
        } else {
          return AuthResponse(
            account: null,
            denied: true,
            error: 'Invalid auth token',
          );
        }
      }

      final account = await getAccountByAuthToken(token);

      if (account == null) {
        return AuthResponse(
          account: null,
          denied: true,
          error: 'Invalid auth token',
        );
      }

      return AuthResponse(
        // TODO Maybe only accountId here!
        account: account,
        denied: false,
        error: null,
      );
    } catch (_) {
      return AuthResponse(
        account: null,
        denied: true,
        error: 'Internal Server Error',
      );
    }
  }

  bool get restrictAccountWhenStorageLimitReached =>
      config['restrictAccountWhenStorageLimitReached'] ?? true;

  Future<void> init(Alfred app) async {
    alwaysAllowedScopes = config['alwaysAllowedScopes']?.cast<String>() ??
        defaultAlwaysAllowedScopes;

    authTokensForAccountRegistration =
        config['authTokensForAccountRegistration']?.cast<String>() ?? [];

    for (final tier in (config['tiers'] ?? defaultTiers)) {
      if (tier['id'] == null) {
        logger.error('accounts config: tier has no id');
        continue;
      }
      final int id = tier['id']!;
      if (tier['storageLimit'] == null) {
        logger.error('accounts config: tier $id has no storageLimit');
        continue;
      }
      tiers[id] = {
        "id": id,
        "name": tier['name'] ?? 'Tier $id',
        "uploadBandwidth": tier['uploadBandwidth'] ?? 100000000,
        "storageLimit": tier['storageLimit'],
        "scopes": tier['scopes'] ?? [],
      };
    }

    sql = SQLService(config, logger);

    await sql.init();

    if ((await sql.db.query('Account', limit: 1)).isEmpty) {
      await createAccount(null);
    }

    final registerChallenges = <String, Uint8List>{};

    app.get(
      '/s5/account/register',
      (req, res) async {
        final auth = await checkAuth(req, 'account/register');
        if (auth.denied) return res.unauthorized(auth);

        final String pubKey = req.uri.queryParameters['pubKey']!;
        final challenge = crypto.generateRandomBytes(32);

        registerChallenges[pubKey] = challenge;

        return {
          'challenge': base64UrlNoPaddingEncode(challenge),
        };
      },
    );

    app.post('/s5/account/register', (req, res) async {
      final auth = await checkAuth(req, 'account/register');
      if (auth.denied) return res.unauthorized(auth);

      final data = await req.bodyAsJsonMap;
      final pubKeyStr = data['pubKey'];
      final challenge = registerChallenges[pubKeyStr];
      if (challenge == null) {
        throw 'No challenge exists for this pubKey';
      }
      final response = base64UrlNoPaddingDecode(data['response']);

      if (response.length != 65) {
        throw 'Invalid response';
      }
      // TODO Validate other parts of response

      final isCorrectChallenge = areBytesEqual(
        challenge,
        response.sublist(1, 33),
      );

      if (!isCorrectChallenge) {
        throw 'Invalid challenge';
      }

      final pubKey = base64UrlNoPaddingDecode(pubKeyStr);

      if (pubKey[0] != 0xed) {
        throw 'Only ed25519 keys are supported';
      }
      final signature = base64UrlNoPaddingDecode(data['signature']);

      final isValid = await crypto.verifyEd25519(
        pk: pubKey.sublist(1),
        message: response,
        signature: signature,
      );

      if (!isValid) {
        throw 'Invalid signature';
      }

      final email = data['email'];
      // TODO Validate email

      final id = await createAccount(email);

      await linkPublicKeyToAccount(id, pubKey);

      final token = await createAuthTokenForAccount(id, data['label']!);

      setSetCookieHeader(res, token, req.requestedUri.authority);
    });

    final loginChallenges = <String, Uint8List>{};

    app.get(
      '/s5/account/login',
      (req, res) async {
        final auth = await checkAuth(req, 'account/login');
        if (auth.denied) return res.unauthorized(auth);

        final String pubKey = req.uri.queryParameters['pubKey']!;
        final challenge = crypto.generateRandomBytes(32);

        loginChallenges[pubKey] = challenge;
        return {
          'challenge': base64UrlNoPaddingEncode(challenge),
        };
      },
    );

    app.post('/s5/account/login', (req, res) async {
      final auth = await checkAuth(req, 'account/login');
      if (auth.denied) return res.unauthorized(auth);

      final data = await req.bodyAsJsonMap;
      final pubKeyStr = data['pubKey'];
      final challenge = loginChallenges[pubKeyStr];
      if (challenge == null) {
        throw 'No challenge exists for this pubKey';
      }
      final response = base64UrlNoPaddingDecode(data['response']);

      if (response.length != 65) {
        throw 'Invalid response';
      }
      // TODO Validate other parts of response

      final isCorrectChallenge =
          areBytesEqual(challenge, response.sublist(1, 33));

      if (!isCorrectChallenge) {
        throw 'Invalid challenge';
      }

      final pubKey = base64UrlNoPaddingDecode(pubKeyStr);

      if (pubKey[0] != 0xed) {
        throw 'Only ed25519 keys are supported';
      }
      final signature = base64UrlNoPaddingDecode(data['signature']);

      final isValid = await crypto.verifyEd25519(
        pk: pubKey.sublist(1),
        message: response,
        signature: signature,
      );

      if (!isValid) {
        throw 'Invalid signature';
      }

      final dbRes = await sql.db.query(
        'PublicKey',
        where: 'public_key = ?',
        whereArgs: [pubKey],
      );
      if (dbRes.isEmpty) {
        throw 'This public key is not registered on this portal';
      }

      final token = await createAuthTokenForAccount(
        dbRes.first['account_id'] as int,
        data['label']!,
      );

      setSetCookieHeader(res, token, req.requestedUri.authority);
    });

    app.get('/s5/account', (req, res) async {
      final auth = await checkAuth(req, 'account/api/account');
      if (auth.denied) return res.unauthorized(auth);

      return {
        "email": auth.account!.email,
        "createdAt": auth.account!.createdAt,
        "quotaExceeded": false,
        "emailConfirmed": false,
        "isRestricted": auth.account!.isRestricted,
        "tier": tiers[auth.account!.tier],
      };
    });

    app.get('/s5/account/stats', (req, res) async {
      final auth = await checkAuth(req, 'account/api/account/stats');
      if (auth.denied) return res.unauthorized(auth);

      final stats = await getStatsForAccount(auth.account!.id);

      final tier = tiers[auth.account!.tier]!;

      final bool quotaExceeded =
          stats['total']['usedStorage'] > tier['storageLimit'];

      bool isRestricted = auth.account!.isRestricted;

      if (quotaExceeded && !isRestricted) {
        if (restrictAccountWhenStorageLimitReached) {
          await setRestrictedStatus(auth.account!.id, true);
          isRestricted = true;
        }
      }

      return {
        "email": auth.account!.email,
        "createdAt": auth.account!.createdAt,
        "quotaExceeded": quotaExceeded,
        "emailConfirmed": false,
        "isRestricted": isRestricted,
        "tier": tier,
        "stats": stats,
      };
    });

    app.get('/s5/account/pins.bin', (req, res) async {
      final auth = await checkAuth(req, 'account/api/account/pins');
      if (auth.denied) return res.unauthorized(auth);

      final cursor =
          await getObjectPinsCursorForAccount(account: auth.account!);
      final pins = await getObjectPinsForAccount(
        account: auth.account!,
        afterCursor: int.parse(
          req.uri.queryParameters['cursor'] ?? '0',
        ),
      );

      final packer = Packer();

      packer.packInt(0);
      packer.packInt(cursor);

      packer.packListLength(pins.length);
      for (final p in pins) {
        packer.packBinary(p.fullBytes);
      }

      res.add(packer.takeBytes());
      res.close();
    });
  }

  Future<Map> getStatsForAccount(int id) async {
    final res = await sql.db.rawQuery('''SELECT SUM(size) as used_storage
FROM Pin
INNER JOIN Object 
    ON Object.hash = Pin.object_hash
WHERE account_id = ?''', [id]);

    return {
      "total": {
        "usedStorage": res.first['used_storage'] ?? 0,
      },
    };
  }

  Future<int> getObjectPinsCursorForAccount({
    required Account account,
  }) async {
    final cursorRes = await sql.db.query(
      'Pin',
      columns: ['created_at'],
      where: 'account_id = ?',
      whereArgs: [account.id],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (cursorRes.isEmpty) {
      return 0;
    }

    return cursorRes.first['created_at'] as int;
  }

  Future<List<Multihash>> getObjectPinsForAccount({
    required Account account,
    int afterCursor = 0,
  }) async {
    final res = await sql.db.rawQuery(
      '''SELECT object_hash
FROM Pin
WHERE account_id = ? AND created_at >= ?''',
      [account.id, afterCursor],
    );

    return res.map((e) => Multihash(e['object_hash'] as Uint8List)).toList();
  }

  Future<void> addObjectPinToAccount({
    required Account account,
    required Multihash hash,
    required int size,
  }) async {
    // TODO Improve performance

    if (size != 0) {
      try {
        await sql.db.insert('Object', {
          'hash': hash.fullBytes,
          'size': size,
          'is_stored': 1,
          'first_seen': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (_) {}
    }

    final res = await sql.db.rawQuery(
      '''SELECT id
FROM Pin
WHERE account_id = ? AND object_hash = ?''',
      [account.id, hash.fullBytes],
    );
    if (res.isEmpty) {
      await sql.db.insert('Pin', {
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'object_hash': hash.fullBytes,
        'account_id': account.id,
      });
    }
  }

  /// returns true if no account pins the file (so it should be deleted)
  Future<bool> deleteObjectPin({
    required Account account,
    required Multihash hash,
  }) async {
    await sql.db.delete(
      'Pin',
      where: 'account_id = ? AND object_hash = ?',
      whereArgs: [account.id, hash.fullBytes],
    );

    final res = await sql.db.rawQuery(
      '''SELECT id
FROM Pin
WHERE object_hash = ?''',
      [hash.fullBytes],
    );
    return res.isEmpty;
  }

  void setSetCookieHeader(HttpResponse res, String token, String domain) {
    res.headers.set(
      'set-cookie',
      's5-auth-token=$token; Path=/; Domain=$domain; Max-Age=2592000; HttpOnly; Secure',
    );
  }

  Future<int> createAccount(String? email) async {
    final res = await sql.db.query(
      'Account',
      where: 'email = ?',
      whereArgs: [email],
    );
    if (res.isNotEmpty) {
      throw 'This email address is already in use by another account on this node';
    }

    return sql.db.insert('Account', {
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'email': email,
      'tier': 1,
    });
  }

  Future<void> deleteAccount(int id) async {
    await sql.db.delete('Pin', where: 'account_id = ?', whereArgs: [id]);
    await sql.db.delete('AuthToken', where: 'account_id = ?', whereArgs: [id]);
    await sql.db.delete('PublicKey', where: 'account_id = ?', whereArgs: [id]);
    await sql.db.delete('Account', where: 'id = ?', whereArgs: [id]);
  }

  Future<Account> getAccountById(int id) async {
    final res = await sql.db.query(
      'Account',
      where: 'id = ?',
      whereArgs: [id],
    );
    final account = res.first;

    return Account(
      id: id,
      createdAt: account['created_at'] as int,
      email: account['email'] as String?,
      isRestricted: account['is_restricted'] == 1,
      tier: account['tier'] as int,
    );
  }

  Future<List<Account>> getAllAccounts() async {
    final res = await sql.db.query(
      'Account',
    );
    return res
        .map<Account>((account) => Account(
              id: account['id'] as int,
              createdAt: account['created_at'] as int,
              email: account['email'] as String?,
              isRestricted: account['is_restricted'] == 1,
              tier: account['tier'] as int,
            ))
        .toList();
  }

  Future<Account?> getAccountByAuthToken(String token) async {
    // TODO Cache responses in-memory for 60 seconds
    final res = await sql.db.rawQuery('''SELECT *
FROM Account
WHERE ID = (
    SELECT account_id
    FROM AuthToken
	WHERE token = ?
);''', [token]);
    if (res.isEmpty) {
      return null;
    }

    final account = res.first;
    return Account(
      id: account['id'] as int,
      createdAt: account['created_at'] as int,
      email: account['email'] as String?,
      isRestricted: account['is_restricted'] == 1,
      tier: account['tier'] as int,
    );
  }

  Future<void> linkPublicKeyToAccount(int accountId, Uint8List publicKey) {
    return sql.db.insert('PublicKey', {
      'public_key': publicKey,
      'account_id': accountId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<String> createAuthTokenForAccount(int accountId, String label) async {
    final token = crypto.generateRandomBytes(32);

    final authToken = 'S5A' + base58BitcoinEncode(token);

    await sql.db.insert('AuthToken', {
      'token': authToken,
      'account_id': accountId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'label': label,
    });
    return authToken;
  }

  Future<void> setRestrictedStatus(int id, bool restricted) async {
    await sql.db.update(
      'Account',
      {'is_restricted': restricted ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setTier(int id, int tier) async {
    await sql.db.update(
      'Account',
      {'tier': tier},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

extension UnauthorizedExtension on HttpResponse {
  Future<dynamic> unauthorized(AuthResponse res) async {
    statusCode = 401;
    write(
      jsonEncode(
        {
          'error': res.error,
        },
      ),
    );
    await close();
  }
}
