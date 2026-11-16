// A failed helper start must stay visible on its card: when the helper
// dies while starting, the card used to flip to Off and hide the very log
// lines that say why it died (the error only lived in a toast). The native
// side now keeps the last start failure in the status map, and the cards
// show it until the next start or stop.
import 'dart:async';

import 'package:flrone/components/aether_panel.dart';
import 'package:flrone/components/psiphon_panel.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

const _failure =
    'Aether stopped while starting\n[2026-11-16T11:53:21.445Z INFO aether::socks] psiphon stopped before it was ready';

Future<void> _pumpDashboard(
  WidgetTester tester,
  MethodChannel channel,
  Map<String, dynamic> helperStatus,
) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final preferences = <String, dynamic>{'locale': 'en', 'aetherChain': false};
  final dashboard = <String, dynamic>{
    'status': 'Stopped',
    'selectedProfileId': 1,
    'modes': ['rule', 'global', 'direct'],
    'mode': 'rule',
    'systemProxyAvailable': false,
    'systemProxy': false,
  };
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'ready':
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': preferences,
          'profiles': [
            {'id': 1, 'name': 'Local profile', 'remote': false},
          ],
          'dashboard': dashboard,
        };
      case 'aether.status':
      case 'psiphon.status':
        return helperStatus;
      case 'dashboard.egress':
        return {'ip': '203.0.113.1', 'country': 'CN', 'type': 'Residential'};
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(
    BoxApp(controller: BoxController(channel: channel, events: events.stream)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump();
}

void main() {
  testWidgets('Aether card keeps a failed start visible across polls',
      (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.helper-start-failure-aether');
    final helperStatus = <String, dynamic>{
      'connected': false,
      'aetherSelected': true,
      'chainSelected': false,
      'psiphonSelected': false,
      'psiphonRegion': '',
      'uptimeMs': 0,
      'startupMs': 90000,
      'log': <String>[
        '[2026-11-16T11:53:21.445Z INFO aether::socks] psiphon stopped before it was ready',
      ],
      'lastError': _failure,
    };
    await _pumpDashboard(tester, channel, helperStatus);
    final card = find.byType(AetherPanel);
    expect(
      find.descendant(of: card, matching: find.text("Couldn't start")),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('psiphon stopped before it was ready'),
      ),
      findsOneWidget,
    );
    // A status poll must not wipe it: the helper is still dead.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(
      find.descendant(of: card, matching: find.text("Couldn't start")),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('psiphon stopped before it was ready'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Psiphon card keeps a failed start visible', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.helper-start-failure-psiphon');
    final helperStatus = <String, dynamic>{
      'connected': false,
      'aetherSelected': false,
      'chainSelected': false,
      'psiphonSelected': true,
      'psiphonRegion': '',
      'uptimeMs': 0,
      'startupMs': 180000,
      'log': <String>[
        '[2026-11-16T11:53:21.445Z INFO aether::socks] psiphon stopped before it was ready',
      ],
      'lastError': _failure,
    };
    await _pumpDashboard(tester, channel, helperStatus);
    final card = find.byType(PsiphonPanel);
    expect(
      find.descendant(of: card, matching: find.text("Couldn't start")),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('psiphon stopped before it was ready'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no start failure, no failure shown', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.helper-start-failure-none');
    final helperStatus = <String, dynamic>{
      'connected': false,
      'aetherSelected': true,
      'chainSelected': false,
      'psiphonSelected': false,
      'psiphonRegion': '',
      'uptimeMs': 0,
      'startupMs': 90000,
      'log': <String>[],
      'lastError': null,
    };
    await _pumpDashboard(tester, channel, helperStatus);
    expect(find.text("Couldn't start"), findsNothing);
    expect(find.text('Off'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
