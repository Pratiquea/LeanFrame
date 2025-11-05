import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// import your files:
import 'package:leanframe/main.dart'; // adjust the path
// If HomeScreen is in another file, import that directly.

void main() {
  testWidgets('pressing "Find connected device" calls discover override',
      (WidgetTester tester) async {
    var called = 0;

    final appState = AppState(); // your existing class
    await tester.pumpWidget(
      MaterialApp(
        home: InheritedAppState(
          notifier: appState,
          child: HomeScreen(
            thisdiscoverOverride: () async {
              called++;
            },
          ),
        ),
      ),
    );

    // Tap the refresh button by tooltip
    final btn = find.byTooltip('Find connected device');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pump(); // allow microtask to run

    expect(called, 1);
  });
}
