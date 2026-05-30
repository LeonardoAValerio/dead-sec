import 'package:flutter_test/flutter_test.dart';
import 'package:safechannel/main.dart';

void main() {
  testWidgets('App smoke test — renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SafeChannelApp());
    expect(find.byType(SafeChannelApp), findsOneWidget);
  });
}
