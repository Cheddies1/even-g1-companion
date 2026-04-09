import 'package:flutter_test/flutter_test.dart';

import 'package:demo_ai_even/main.dart';

void main() {
  testWidgets('app renders companion home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const EvenCompanionApp());

    expect(find.text('Even Companion'), findsWidgets);
    expect(find.text('Modes'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
  });
}
