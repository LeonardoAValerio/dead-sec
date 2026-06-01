import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

// Isola o arquivo de banco por instância em desenvolvimento multi-peer.
const _instanceId = String.fromEnvironment('INSTANCE_ID', defaultValue: '');

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
  final dbPath = _desktopDbPath();
  await Directory(p.dirname(dbPath)).create(recursive: true);
  return ffi.databaseFactory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: _createSchema,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
    ),
  );
}

String _desktopDbPath() {
  final suffix = _instanceId.isNotEmpty ? '_$_instanceId' : '';
  if (Platform.isLinux || Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, '.local', 'share', 'safechannel$suffix', 'safechannel.db');
  }
  // Windows
  final appData = Platform.environment['APPDATA'] ?? '.';
  return p.join(appData, 'SafeChannel$suffix', 'safechannel.db');
}

/// Abre um banco em memória para testes automatizados.
/// Usa o mesmo schema de produção — não persiste dados entre testes.
Future<Database> openTestDatabase() async {
  ffi.sqfliteFfiInit();
  ffi.databaseFactory = ffi.databaseFactoryFfi;
  return ffi.databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
  );
}

/// Deleta o banco de dados local no desktop (Linux/macOS/Windows).
/// Chamado ao resetar a instância com --dart-define=RESET_ON_START=true.
Future<void> resetDesktopDatabase() async {
  if (!_isDesktopOrWeb) return;
  final dbPath = _desktopDbPath();
  final file = File(dbPath);
  if (await file.exists()) await file.delete();
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
      signal_key         BLOB,
      signal_pre_key     BLOB,
      signal_pre_key_sig BLOB,
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
