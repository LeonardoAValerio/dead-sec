import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

/// Abre o banco de dados local.
///
/// Android/iOS: SQLCipher com chave derivada do PIN (SPEC-CRYPTO-003).
/// Web/Linux/macOS/Windows: sqflite_common_ffi sem criptografia — apenas para desenvolvimento.
/// A chave NUNCA é passada em texto claro para o storage — vem sempre do KeyManager.
Future<Database> openAppDatabase(String encryptionKey) async {
  if (_isDesktopOrWeb) {
    return _openDesktopDatabase();
  }
  return _openMobileDatabase(encryptionKey);
}

bool get _isDesktopOrWeb =>
    kIsWeb || (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows));

Future<Database> _openMobileDatabase(String encryptionKey) async {
  final dbPath = p.join(await cipher.getDatabasesPath(), 'safechannel.db');

  // sqflite_sqlcipher expõe openDatabase com parâmetro `password` (SPEC-CRYPTO-003)
  return cipher.openDatabase(
    dbPath,
    password: encryptionKey,
    version: 1,
    onCreate: _createSchema,
    onConfigure: (db) async {
      await db.execute('PRAGMA journal_mode=WAL');
      await db.execute('PRAGMA foreign_keys=ON');
    },
  );
}

Future<Database> _openDesktopDatabase() async {
  ffi.sqfliteFfiInit();
  ffi.databaseFactory = ffi.databaseFactoryFfi;
  return ffi.databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
  );
}

Future<void> _createSchema(Database db, int version) async {
  final batch = db.batch();

  batch.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      identity_public_key BLOB NOT NULL,
      signed_pre_key_public BLOB NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  batch.execute('''
    CREATE TABLE channels (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      channel_key BLOB NOT NULL,
      invite_secret_hash TEXT NOT NULL,
      created_by TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      auto_delete_seconds INTEGER,
      max_members INTEGER NOT NULL DEFAULT 50,
      allow_media INTEGER NOT NULL DEFAULT 1
    )
  ''');

  batch.execute('''
    CREATE TABLE channel_members (
      channel_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      public_key BLOB NOT NULL,
      role TEXT NOT NULL DEFAULT 'member',
      joined_at INTEGER NOT NULL,
      vector_clock TEXT NOT NULL DEFAULT '{}',
      PRIMARY KEY (channel_id, user_id),
      FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
    )
  ''');

  batch.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      channel_id TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'text',
      payload BLOB NOT NULL,
      metadata TEXT,
      timestamp INTEGER NOT NULL,
      vector_clock TEXT NOT NULL DEFAULT '{}',
      signature BLOB NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
    )
  ''');

  batch.execute('CREATE INDEX idx_messages_channel ON messages(channel_id, timestamp)');
  batch.execute('CREATE INDEX idx_messages_status ON messages(status)');

  await batch.commit(noResult: true);
}
