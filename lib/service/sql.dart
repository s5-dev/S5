import 'package:s5_server/logger/base.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common/sqlite_api.dart';

class SQLService {
  final Map config;
  final Logger logger;

  SQLService(this.config, this.logger);

  late final Database db;

  Future<void> init() async {
    logger.info('[sqlite] init');

    sqfliteFfiInit();

    var databaseFactory = databaseFactoryFfi;

    await databaseFactory.setDatabasesPath(config['database']['path']);

    db = await databaseFactory.openDatabase(
      'accounts.db',
    );

    await db.execute('''
  CREATE TABLE IF NOT EXISTS User (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE,
      created_at INTEGER NOT NULL,
      tier INTEGER NOT NULL
  )
  ''');

    // TODO public keys can have scopes

    await db.execute('''
  CREATE TABLE IF NOT EXISTS PublicKey (
      public_key VARBINARY(64) NOT NULL PRIMARY KEY,
      created_at INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      FOREIGN KEY(user_id) REFERENCES User(id)
  )
  ''');
    await db.execute('''
  CREATE TABLE IF NOT EXISTS AuthToken (
      token CHAR(86) NOT NULL PRIMARY KEY,
      created_at INTEGER NOT NULL,
      label varchar(64) NOT NULL,
      user_id INTEGER NOT NULL,
      FOREIGN KEY(user_id) REFERENCES User(id)
  )
  ''');

    await db.execute('''
  CREATE TABLE IF NOT EXISTS Object (
      hash VARBINARY(64) NOT NULL PRIMARY KEY,
      size INTEGER NOT NULL,
      is_stored TINYINT(1) NOT NULL,
      first_seen INTEGER NOT NULL
  )
  ''');

    await db.execute('''
  CREATE TABLE IF NOT EXISTS Pin (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at INTEGER NOT NULL,

      object_hash VARBINARY(64) NOT NULL,
      user_id INTEGER NOT NULL,
      
      FOREIGN KEY(object_hash) REFERENCES Object(hash),
      FOREIGN KEY(user_id) REFERENCES User(id)
  )
  ''');
  }
}
