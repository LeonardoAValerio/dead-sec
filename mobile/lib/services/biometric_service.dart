import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kPrefKey = 'biometrics_enabled';
const _kDbKeyEntry = 'biometric_db_key';

const _storage = FlutterSecureStorage();

/// Abstração sobre local_auth com fallback silencioso em plataformas sem suporte.
class BiometricService {
  static final _auth = LocalAuthentication();

  /// Verifica se biometria está disponível no dispositivo.
  /// Retorna false silenciosamente no Linux/macOS desktop (sem mensagem de erro).
  static Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Lê preferência de biometria habilitada.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPrefKey) ?? false;
  }

  /// Habilita biometria: salva a DB key derivada no secure_storage e grava pref.
  static Future<void> enable(String derivedDbKey) async {
    await _storage.write(key: _kDbKeyEntry, value: derivedDbKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefKey, true);
  }

  /// Desabilita biometria: remove a DB key do storage e limpa a pref.
  static Future<void> disable() async {
    await _storage.delete(key: _kDbKeyEntry);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefKey, false);
  }

  /// Executa o prompt biométrico.
  /// Retorna a DB key se autenticação bem-sucedida, null caso contrário.
  static Future<String?> authenticate() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Autentique-se para acessar o SafeChannel',
      );
      if (!ok) return null;
      return _storage.read(key: _kDbKeyEntry);
    } catch (_) {
      return null;
    }
  }

  /// Atualiza a DB key armazenada (necessário após troca de PIN).
  static Future<void> updateStoredKey(String newDbKey) async {
    await _storage.write(key: _kDbKeyEntry, value: newDbKey);
  }
}
