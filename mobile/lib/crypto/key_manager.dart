import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;
import 'package:uuid/uuid.dart';

/// Gerencia as chaves criptográficas do usuário.
///
/// **Mobile (Android/iOS):** flutter_secure_storage → Keystore/Keychain (SPEC-DATA-001).
/// **Desktop (Linux/macOS/Windows):** arquivo JSON com chmod 600 em
///   `~/.local/share/safechannel_<instanceId>/keystore.json`.
///   Aceitável para desenvolvimento — não use em produção sem auditoria.
///
/// `--dart-define=INSTANCE_ID=alice` isola as chaves de cada instância.
class KeyManager {
  // Usado apenas em mobile (Android/iOS)
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    lOptions: LinuxOptions(),
  );

  static const _instanceId = String.fromEnvironment('INSTANCE_ID', defaultValue: '');
  static String _k(String name) =>
      _instanceId.isEmpty ? name : '${_instanceId}_$name';

  static String get _kIdentityKey => _k('identity_key_v1');
  static String get _kSignedPreKey => _k('signed_pre_key_v1');
  static String get _kSignalIdentityKey => _k('signal_identity_v1');
  static String get _kDbKeySalt => _k('db_key_v1_salt');

  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();

  // ─── Roteamento de storage: mobile = keyring, desktop = arquivo ──────────

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  static Future<String?> _read(String key) async {
    if (_isDesktop) return _FileKeyStore.read(key);
    return _secureStorage.read(key: key);
  }

  static Future<void> _write(String key, String value) async {
    if (_isDesktop) {
      await _FileKeyStore.write(key, value);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }

  static Future<void> _deleteAll() async {
    if (_isDesktop) {
      await _FileKeyStore.deleteAll();
      return;
    }
    await _secureStorage.deleteAll();
  }

  // ─── Geração de chaves ───────────────────────────────────────────────────

  /// Gera e persiste as 3 chaves criptográficas necessárias para o SafeChannel.
  /// Chamado uma única vez durante o onboarding.
  static Future<KeyBundle> generateAndStoreKeys() async {
    final identityKeyPair    = await _ed25519.newKeyPair();
    final signedPreKeyPair   = await _x25519.newKeyPair();
    final signalIdentityPair = await _x25519.newKeyPair();

    final identityPrivBytes      = await identityKeyPair.extractPrivateKeyBytes();
    final identityPubBytes       = (await identityKeyPair.extractPublicKey()).bytes;
    final preKeyPrivBytes        = await signedPreKeyPair.extractPrivateKeyBytes();
    final preKeyPubBytes         = (await signedPreKeyPair.extractPublicKey()).bytes;
    final signalIdPrivBytes      = await signalIdentityPair.extractPrivateKeyBytes();
    final signalIdPubBytes       = (await signalIdentityPair.extractPublicKey()).bytes;

    await _write(_kIdentityKey,     base64Encode(identityPrivBytes));
    await _write(_kSignedPreKey,    base64Encode(preKeyPrivBytes));
    await _write(_kSignalIdentityKey, base64Encode(signalIdPrivBytes));

    return KeyBundle(
      userId: const Uuid().v4(),
      identityPublicKey:       Uint8List.fromList(identityPubBytes),
      signedPreKeyPublic:      Uint8List.fromList(preKeyPubBytes),
      signalIdentityPublicKey: Uint8List.fromList(signalIdPubBytes),
    );
  }

  // ─── Leitura de chaves ───────────────────────────────────────────────────

  static Future<SimpleKeyPair> loadIdentityKeyPair() async {
    final privB64 = await _read(_kIdentityKey);
    if (privB64 == null) throw StateError('Identity key not found — run onboarding first');
    return _ed25519.newKeyPairFromSeed(base64Decode(privB64));
  }

  static Future<SimpleKeyPair> loadSignedPreKeyPair() async {
    final privB64 = await _read(_kSignedPreKey);
    if (privB64 == null) throw StateError('Signed pre-key not found — run onboarding first');
    return _x25519.newKeyPairFromSeed(base64Decode(privB64));
  }

  /// Chave de identidade Signal (X25519) para DH no X3DH.
  /// Distinta da identity key Ed25519 usada para assinatura.
  static Future<SimpleKeyPair> loadSignalIdentityKeyPair() async {
    final privB64 = await _read(_kSignalIdentityKey);
    if (privB64 == null) throw StateError('Signal identity key not found — run onboarding first');
    return _x25519.newKeyPairFromSeed(base64Decode(privB64));
  }

  // ─── Chave do banco de dados ──────────────────────────────────────────────

  /// Deriva a chave de criptografia do banco a partir do PIN via Argon2id.
  /// Parâmetros: memória 64MB, iterações 3, paralelismo 4 (SPEC-CHAN-002).
  /// O cálculo pesado roda em isolate separado para não bloquear a UI nem causar ANR.
  static Future<String> deriveDbKey(String pin) async {
    String? saltB64 = await _read(_kDbKeySalt);
    late Uint8List salt;
    if (saltB64 == null) {
      final rng = pc.SecureRandom('Fortuna')
        ..seed(pc.KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => DateTime.now().microsecondsSinceEpoch & 0xFF),
        )));
      salt = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        salt[i] = rng.nextUint8();
      }
      await _write(_kDbKeySalt, base64Encode(salt));
    } else {
      salt = base64Decode(saltB64);
    }

    final pinBytes = Uint8List.fromList(utf8.encode(pin));
    return compute(_argon2DeriveIsolate, [pinBytes, salt]);
  }

  // Função top-level equivalente exigida pelo compute() — roda em isolate separado.
  static String _argon2DeriveIsolate(List<Uint8List> args) {
    final pinBytes = args[0];
    final salt = args[1];
    final params = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 32,
      iterations: 3,
      memory: 65536,
      lanes: 4,
    );
    final generator = pc.Argon2BytesGenerator()..init(params);
    final key = Uint8List(32);
    generator.deriveKey(pinBytes, 0, key, 0);
    return base64Encode(key);
  }

  static Future<bool> hasKeys() async {
    final key = await _read(_kIdentityKey);
    return key != null;
  }

  /// Gera a chave de identidade Signal (signal_identity_v1) se ela não existir ainda.
  /// Chamado no startup para migrar keystores antigos que foram criados antes dessa chave
  /// ser adicionada ao generateAndStoreKeys().
  static Future<void> ensureSignalIdentityKey() async {
    final existing = await _read(_kSignalIdentityKey);
    if (existing != null) return;
    final signalIdentityPair = await _x25519.newKeyPair();
    final privBytes = await signalIdentityPair.extractPrivateKeyBytes();
    await _write(_kSignalIdentityKey, base64Encode(privBytes));
  }

  static Future<void> deleteAllKeys() async => _deleteAll();
}

// ─── Armazenamento em arquivo para desktop (Linux/macOS/Windows) ──────────

/// Armazena chaves em JSON com chmod 600 no mesmo diretório do banco.
/// Usado apenas em desenvolvimento desktop — mobile usa flutter_secure_storage.
class _FileKeyStore {
  static const _instanceId = String.fromEnvironment('INSTANCE_ID', defaultValue: '');

  static String _keystorePath() {
    final suffix = _instanceId.isNotEmpty ? '_$_instanceId' : '';
    if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return p.join(home, '.local', 'share', 'safechannel$suffix', 'keystore.json');
    }
    final appData = Platform.environment['APPDATA'] ?? '.';
    return p.join(appData, 'SafeChannel$suffix', 'keystore.json');
  }

  static Future<Map<String, String>> _loadAll() async {
    try {
      final file = File(_keystorePath());
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      return Map<String, String>.from(jsonDecode(content) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveAll(Map<String, String> data) async {
    final path = _keystorePath();
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data));
    // Restringe permissões: apenas o usuário pode ler/escrever.
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['600', path]);
    }
  }

  static Future<String?> read(String key) async {
    final data = await _loadAll();
    return data[key];
  }

  static Future<void> write(String key, String value) async {
    final data = await _loadAll();
    data[key] = value;
    await _saveAll(data);
  }

  static Future<void> deleteAll() async {
    try {
      final file = File(_keystorePath());
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class KeyBundle {
  final String userId;
  final Uint8List identityPublicKey;
  final Uint8List signedPreKeyPublic;
  final Uint8List signalIdentityPublicKey;

  const KeyBundle({
    required this.userId,
    required this.identityPublicKey,
    required this.signedPreKeyPublic,
    required this.signalIdentityPublicKey,
  });
}
