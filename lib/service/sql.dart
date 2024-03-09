import 'package:lib5/util.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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

    final dbVersion = await db.getVersion();

    if (dbVersion == 0) {
      final userTableRes = await db.query(
        'sqlite_master',
        columns: ['name'],
        where: "type = 'table' AND name='User'",
      );

      if (userTableRes.isEmpty) {
        logger.info('[sqlite] creating tables in new db...');

        await db.execute('''
  CREATE TABLE IF NOT EXISTS Account (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE,
      created_at INTEGER NOT NULL,
      tier INTEGER NOT NULL,
      is_restricted TINYINT(1) NOT NULL DEFAULT 0
  )
  ''');

        await db.execute('''
  CREATE TABLE IF NOT EXISTS PublicKey (
      public_key VARBINARY(64) NOT NULL PRIMARY KEY,
      created_at INTEGER NOT NULL,
      account_id INTEGER NOT NULL,
      FOREIGN KEY(account_id) REFERENCES Account(id)
  )
  ''');
        await db.execute('''
  CREATE TABLE IF NOT EXISTS AuthToken (
      token CHAR(86) NOT NULL PRIMARY KEY,
      created_at INTEGER NOT NULL,
      label varchar(64) NOT NULL,
      account_id INTEGER NOT NULL,
      FOREIGN KEY(account_id) REFERENCES Account(id)
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
      account_id INTEGER NOT NULL,
      
      FOREIGN KEY(object_hash) REFERENCES Object(hash),
      FOREIGN KEY(account_id) REFERENCES Account(id)
  )
  ''');
      } else {
        logger.info('[sqlite] migrating pre-v0.11.0 db...');

        await db.transaction((txn) async {
          await txn.execute('ALTER TABLE User RENAME TO Account');
          await txn.execute(
            'ALTER TABLE PublicKey RENAME COLUMN user_id TO account_id',
          );
          await txn.execute(
            'ALTER TABLE AuthToken RENAME COLUMN user_id TO account_id',
          );
          await txn.execute(
            'ALTER TABLE Pin RENAME COLUMN user_id TO account_id',
          );
          await txn.execute(
            "ALTER TABLE Account ADD COLUMN is_restricted TINYINT(1) NOT NULL DEFAULT 0",
          );
        });
      }
      await db.setVersion(1);
      logger.info('[sqlite] done');
    }
  }
}
