import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auri/core/widgets/exit_confirm.dart';

void main() {
  testWidgets('Back on the root screen asks before exiting (Android)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const MaterialApp(
      home: ExitConfirmScope(appName: 'Test', child: Scaffold()),
    ));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Exit Test?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Exit Test?'), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
