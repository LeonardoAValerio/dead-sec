import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:safechannel/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NotificationService — preferências', () {
    test('isEnabled retorna true por padrão (sem pref gravada)', () async {
      expect(await NotificationService.isEnabled(), isTrue);
    });

    test('setEnabled(false) → isEnabled retorna false', () async {
      await NotificationService.setEnabled(false);
      expect(await NotificationService.isEnabled(), isFalse);
    });

    test('setEnabled(true) após false → isEnabled retorna true', () async {
      await NotificationService.setEnabled(false);
      await NotificationService.setEnabled(true);
      expect(await NotificationService.isEnabled(), isTrue);
    });
  });
}
