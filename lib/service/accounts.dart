import 'dart:convert';
import 'dart:typed_data';

import 'package:alfred/alfred.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/util.dart';

import 'package:s5_server/accounts/user.dart';
import 'package:s5_server/logger/base.dart';
import 'package:s5_server/service/sql.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AuthResponse {
  final User? user;
  final bool denied;
  final String? error;

  AuthResponse({
    required this.user,
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

  late final Alfred app;

  final alwaysAllowedScopes = [
    'account/login',
    'account/register',
    's5/registry/read',
    's5/subdomain/load',
    's5/metadata',
    's5/debug/dl_uris',
  ];

  Future<AuthResponse> checkAuth(HttpRequest req, String scope) async {
    if (alwaysAllowedScopes.contains(scope)) {
      return AuthResponse(
        user: null,
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
        // TODO Check if scope is public
        return AuthResponse(
          user: null,
          denied: true,
          error: 'No token found',
        );
      }
      final user = await getUserByAuthToken(token);

      if (user == null) {
        return AuthResponse(
          user: null,
          denied: true,
          error: 'Invalid token',
        );
      }

      return AuthResponse(
        // TODO Maybe only userId here!
        user: user,
        denied: false,
        error: null,
      );
    } catch (_) {
      return AuthResponse(
        user: null,
        denied: true,
        error: 'Internal Server Error',
      );
    }
  }

  Future<void> init() async {
    sql = SQLService(config, logger);

    await sql.init();
    app = Alfred();

    final registerChallenges = <String, Uint8List>{};

    app.get(
      '/api/register',
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

    app.post('/api/register', (req, res) async {
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

      final id = await createUser(email);

      await linkPublicKeyToUser(id, pubKey);

      final token = await createAuthTokenForUser(id, data['label']!);

      setSetCookieHeader(res, token, req.requestedUri.authority);
    });

    final loginChallenges = <String, Uint8List>{};

    app.get(
      '/api/login',
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

    app.post('/api/login', (req, res) async {
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

      final token = await createAuthTokenForUser(
        dbRes.first['user_id'] as int,
        data['label']!,
      );

      setSetCookieHeader(res, token, req.requestedUri.authority);
    });

    // TODO Move tiers to config
    final tiers = [
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
        "scopes": ["test"],
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

    app.get('/api/user', (req, res) async {
      final auth = await checkAuth(req, 'account/api/user');
      if (auth.denied) return res.unauthorized(auth);

      return {
        "email": auth.user!.email,
        "createdAt": auth.user!.createdAt,
        "quotaExceeded": false,
        "emailConfirmed": false,
        "tier": tiers[auth.user!.tier],
      };
    });

    app.get('/api/user/stats', (req, res) async {
      final auth = await checkAuth(req, 'account/api/user');
      if (auth.denied) return res.unauthorized(auth);

      final stats = await getStatsForUser(auth.user!.id);

      return {
        "email": auth.user!.email,
        "createdAt": auth.user!.createdAt,
        "quotaExceeded": false,
        "emailConfirmed": false,
        "tier": tiers[auth.user!.tier],
        "stats": stats,
      };
    });
  }

  Future<Map> getStatsForUser(int id) async {
    final res = await sql.db.rawQuery('''SELECT SUM(size) as used_storage
FROM Pin
INNER JOIN Object 
    ON Object.hash = Pin.object_hash
WHERE user_id = ?''', [id]);

    return {
      "total": {
        "usedStorage": res.first['used_storage'] ?? 0,
      },
    };
  }

  Future<void> addObjectPinToUser({
    required User user,
    required Multihash hash,
    required int size,
  }) async {
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
    await sql.db.insert('Pin', {
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'object_hash': hash.fullBytes,
      'user_id': user.id,
    });
  }

  void setSetCookieHeader(HttpResponse res, String token, String domain) {
    res.headers.set(
      'set-cookie',
      's5-auth-token=$token; Path=/; Domain=$domain; Max-Age=2592000; HttpOnly; Secure',
    );
  }

  Future<int> createUser(String? email) {
    return sql.db.insert('User', {
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'email': email,
      'tier': 1,
    });
  }

  Future<User> getUserById(int id) async {
    final res = await sql.db.query(
      'User',
      where: 'id = ?',
      whereArgs: [id],
    );
    final user = res.first;
    return User(
      id: id,
      createdAt: user['created_at'] as int,
      email: user['email'] as String?,
    );
  }

  Future<User?> getUserByAuthToken(String token) async {
    // TODO Cache responses in-memory for 60 seconds
    final res = await sql.db.rawQuery('''SELECT *
FROM User
WHERE ID = (
    SELECT user_id
    FROM AuthToken
	WHERE token = ?
);''', [token]);
    if (res.isEmpty) {
      return null;
    }

    final user = res.first;
    return User(
      id: user['id'] as int,
      createdAt: user['created_at'] as int,
      email: user['email'] as String?,
    );
  }

  Future<void> linkPublicKeyToUser(int userId, Uint8List publicKey) {
    return sql.db.insert('PublicKey', {
      'public_key': publicKey,
      'user_id': userId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<String> createAuthTokenForUser(int userId, String label) async {
    final token = crypto.generateRandomBytes(64);

    final authToken = base64UrlNoPaddingEncode(token);

    await sql.db.insert('AuthToken', {
      'token': authToken,
      'user_id': userId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'label': label,
    });
    return authToken;
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
