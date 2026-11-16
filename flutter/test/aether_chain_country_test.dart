import 'dart:async';

import 'package:flrone/components/aether_panel.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

void main() {
  for (final chained in [false, true]) {
    testWidgets(
      'Aether card ${chained ? 'shows' : 'hides'} the country picker when ${chained ? 'chained' : 'alone'}',
      (tester) async {
        reportFlutterErrors();
        // Tall enough for the Aether card to be built at once.
        tester.view.physicalSize = const Size(360, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final events = StreamController<dynamic>.broadcast();
        const channel = MethodChannel('test.aether-chain-country');
        final preferences = <String, dynamic>{'locale': 'en', 'aetherChain': chained};
        final dashboard = <String, dynamic>{
          'status': 'Started',
          'selectedProfileId': 1,
          'modes': ['rule', 'global', 'direct'],
          'mode': 'rule',
          'systemProxyAvailable': false,
          'systemProxy': false,
        };
        final helperStatus = <String, dynamic>{
          'connected': false,
          'aetherSelected': !chained,
          'chainSelected': chained,
          'psiphonSelected': false,
          'psiphonRegion': chained ? 'DE' : '',
          'uptimeMs': 0,
          'startupMs': 90000,
          'log': <String>[],
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
        // The picker lives on the Aether card only when chained. The
        // Psiphon card has its own picker, so scope the search to the
        // Aether card — an unscoped find would always match Psiphon.
        final picker = find.descendant(
          of: find.byType(AetherPanel),
          matching: find.text('Exit country'),
        );
        expect(
          find.descendant(
            of: find.byType(AetherPanel),
            matching: find.text('Chain with Psiphon'),
          ),
          findsOneWidget,
        );
        if (chained) {
          expect(picker, findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AetherPanel),
              matching: find.text('Germany'),
            ),
            findsOneWidget,
          );
        } else {
          expect(picker, findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
