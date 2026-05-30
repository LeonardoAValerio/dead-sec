import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:uuid/uuid.dart';

/// Gerencia as chaves criptográficas do usuário.
///
/// Chaves privadas ficam exclusivamente no secure enclave (Android Keystore / iOS Keychain)
/// via flutter_secure_storage. NUNCA são expostas em texto claro (SPEC-DATA-001).
///
/// Em desenvolvimento, `--dart-define=INSTANCE_ID=alice` isola as chaves de cada instância
/// no mesmo keyring Linux, permitindo testar dois peers na mesma máquina.
class KeyManager {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  // Prefixo por instância — permite isolar chaves de dois peers no mesmo Linux keyring.
  // Uso: flutter run --dart-define=INSTANCE_ID=alice
  static const _instanceId = String.fromEnvironment('INSTANCE_ID', defaultValue: '');
  static String _k(String name) =>
      _instanceId.isEmpty ? name : '${_instanceId}_$name';

  static String get _kIdentityKeyAlgorithm => _k('identity_key_v1');
  static String get _kSignedPreKeyAlgorithm => _k('signed_pre_key_v1');
  static String get _kDbKeyAlgorithm => _k('db_key_v1');

  // Algoritmos criptográficos
  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();

  // ─── Geração de chaves ───────────────────────────────────────────────────

  /// Gera e persiste as chaves de identidade (Ed25519) e pré-chave assinada (X25519).
  /// Deve ser chamado uma única vez durante o onboarding.
  static Future<KeyBundle> generateAndStoreKeys() async {
    final identityKeyPair = await _ed25519.newKeyPair();
    final signedPreKeyPair = await _x25519.newKeyPair();

    final identityPrivBytes = await identityKeyPair.extractPrivateKeyBytes();
    final identityPubBytes = (await identityKeyPair.extractPublicKey()).bytes;
    final preKeyPrivBytes = await signedPreKeyPair.extractPrivateKeyBytes();
    final preKeyPubBytes = (await signedPreKeyPair.extractPublicKey()).bytes;

    await _storage.write(key: _kIdentityKeyAlgorithm, value: base64Encode(identityPrivBytes));
    await _storage.write(key: _kSignedPreKeyAlgorithm, value: base64Encode(preKeyPrivBytes));

    return KeyBundle(
      userId: const Uuid().v4(),
      identityPublicKey: Uint8List.fromList(identityPubBytes),
      signedPreKeyPublic: Uint8List.fromList(preKeyPubBytes),
    );
  }

  // ─── Leitura de chaves ───────────────────────────────────────────────────

  static Future<SimpleKeyPair> loadIdentityKeyPair() async {
    final privB64 = await _storage.read(key: _kIdentityKeyAlgorithm);
    if (privB64 == null) throw StateError('Identity key not found — run onboarding first');
    final privBytes = base64Decode(privB64);
    return _ed25519.newKeyPairFromSeed(privBytes);
  }

  static Future<SimpleKeyPair> loadSignedPreKeyPair() async {
    final privB64 = await _storage.read(key: _kSignedPreKeyAlgorithm);
    if (privB64 == null) throw StateError('Signed pre-key not found — run onboarding first');
    final privBytes = base64Decode(privB64);
    return _x25519.newKeyPairFromSeed(privBytes);
  }

  // ─── Chave do banco de dados ──────────────────────────────────────────────

  /// Deriva a chave de criptografia do banco a partir do PIN do usuário via Argon2id.
  /// Parâmetros obrigatórios: memória 64MB, iterações 3, paralelismo 4 (SPEC-CHAN-002).
  static Future<String> deriveDbKey(String pin) async {
    // Recupera ou gera salt persistente para este dispositivo
    String? saltB64 = await _storage.read(key: '${_kDbKeyAlgorithm}_salt');
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
      await _storage.write(key: '${_kDbKeyAlgorithm}_salt', value: base64Encode(salt));
    } else {
      salt = base64Decode(saltB64);
    }

    // Argon2id com parâmetros mínimos da spec
    final params = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 32,
      iterations: 3,
      memory: 65536, // 64 MB em KB
      lanes: 4,
    );
    final generator = pc.Argon2BytesGenerator()..init(params);
    final pinBytes = Uint8List.fromList(utf8.encode(pin));
    final key = Uint8List(32);
    // pointycastle 4.x usa deriveKey (não generateBytes)
    generator.deriveKey(pinBytes, 0, key, 0);

    return base64Encode(key);
  }

  static Future<bool> hasKeys() async {
    final key = await _storage.read(key: _kIdentityKeyAlgorithm);
    return key != null;
  }

  static Future<void> deleteAllKeys() async {
    await _storage.deleteAll();
  }
}

class KeyBundle {
  final String userId;
  final Uint8List identityPublicKey;
  final Uint8List signedPreKeyPublic;

  const KeyBundle({
    required this.userId,
    required this.identityPublicKey,
    required this.signedPreKeyPublic,
  });
}
