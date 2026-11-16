import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:flrone/components/helper_country.dart';
import 'package:flrone/widgets.dart';

void main() {
  testWidgets('picker fits at 360px', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      material.MaterialApp(
        home: material.Center(
          child: material.SizedBox(
            width: 328,
            child: BoxPanel(
              child: HelperCountryPicker(value: '', onSelected: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker shows the chosen country', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      material.MaterialApp(
        home: material.Center(
          child: material.SizedBox(
            width: 328,
            child: BoxPanel(
              child: HelperCountryPicker(value: 'DE', onSelected: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Germany'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
