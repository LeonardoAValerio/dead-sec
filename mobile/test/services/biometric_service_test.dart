import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safechannel/services/biometric_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Mock flutter_secure_storage — canal de plataforma não disponível em testes.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'read') return null;
        return null; // write, delete, deleteAll → no-op
      },
    );
  });

  group('BiometricService — preferências', () {
    test('isEnabled retorna false por padrão', () async {
      expect(await BiometricService.isEnabled(), isFalse);
    });

    test('isAvailable não lança exceção em ambiente de teste', () async {
      // No ambiente de CI/desktop sem hardware biométrico, deve retornar false sem travar.
      final available = await BiometricService.isAvailable();
      expect(available, isA<bool>());
    });

    test('disable sem enable prévia não lança exceção', () async {
      // Garante que a chamada é idempotente mesmo sem chave gravada.
      await expectLater(BiometricService.disable(), completes);
      expect(await BiometricService.isEnabled(), isFalse);
    });
  });
}
