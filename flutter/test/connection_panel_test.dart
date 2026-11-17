// The unified Connection card: one mode selector for Aether, Psiphon and
// the chain; the country picker only where Psiphon is involved; the
// New/Previous IP choice before connecting; and the mode-switch fix —
// switching mode stops the previous helper first, so the old tunnel
// never keeps running behind the new one.
import 'dart:async';

import 'package:flrone/components/connection_panel.dart';
import 'package:flrone/components/connected_buttons.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/dashboard.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

const _failure =
    'Aether stopped while starting\n[2026-11-16T11:53:21.445Z INFO aether::socks] psiphon stopped before it was ready';

/// The mock native side: it models what the runner does, so the panel's
/// decisions are testable without a phone. Selecting a profile switches
/// the selected flags and the running mode; stopping the helper takes it
/// down; every call is recorded in [calls] in order.
class _MockHost {
  _MockHost({
    required this.preferences,
    required this.helperStatus,
    required this.dashboard,
    required this.calls,
  });

  final Map<String, dynamic> preferences;
  final Map<String, dynamic> helperStatus;
  final Map<String, dynamic> dashboard;
  final List<MethodCall> calls;

  Future<dynamic> handle(MethodCall call) async {
    calls.add(call);
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
      case 'preferences.set':
        preferences.addAll(json((call.arguments as Map)['value']));
        return preferences;
      case 'aether.ensure':
        return {'profileId': 10};
      case 'psiphon.ensure':
        return {'profileId': 11};
      case 'psiphon.ensureChain':
        return {'profileId': 12};
      case 'aether.stop':
        helperStatus['connected'] = false;
        helperStatus['running'] = false;
        helperStatus['mode'] = null;
        helperStatus['lastError'] = null;
        return {'running': false};
      case 'aether.rescan':
      case 'aether.reconnect':
        return helperStatus;
      case 'helper.setCountries':
        helperStatus['psiphonRegion'] =
            (call.arguments as Map)['psiphonRegion'] as String? ?? '';
        return helperStatus;
      case 'profiles.select':
        final id = (call.arguments as Map)['id'] as int?;
        helperStatus['aetherSelected'] = id == 10;
        helperStatus['psiphonSelected'] = id == 11;
        helperStatus['chainSelected'] = id == 12;
        helperStatus['mode'] = switch (id) {
          11 => 'psiphon',
          12 => 'chain',
          _ => 'aether',
        };
        dashboard['selectedProfileId'] = id;
        return true;
    }
    return null;
  }
}

Map<String, dynamic> _helperStatus({
  required String mode,
  bool connected = false,
  String region = '',
  int uptimeMs = 0,
  List<String> log = const [],
  String? lastError,
}) {
  final startupMs = switch (mode) {
    'psiphon' => 180000,
    'chain' => 270000,
    _ => 90000,
  };
  return {
    'connected': connected,
    'running': connected,
    'mode': connected ? mode : null,
    'aetherSelected': mode == 'aether',
    'psiphonSelected': mode == 'psiphon',
    'chainSelected': mode == 'chain',
    'psiphonRegion': region,
    'uptimeMs': uptimeMs,
    'startupMs': startupMs,
    'log': log,
    'lastError': lastError,
  };
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  MethodChannel channel,
  _MockHost host,
) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, host.handle);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  addTearDown(events.close);
  await tester.pumpWidget(
    BoxApp(controller: BoxController(channel: channel, events: events.stream)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump();
}

bool _segmentSelected(WidgetTester tester, String label) {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byType(DashboardConnectedButton),
  );
  return tester.widget<DashboardConnectedButton>(button).selected;
}

void main() {
  testWidgets('switching mode stops the previous helper first',
      (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.connection-mode-switch');
    final calls = <MethodCall>[];
    final host = _MockHost(
      preferences: <String, dynamic>{
        'locale': 'en',
        'helperMode': 'chain',
        'helperStartWith': 'new',
        'aetherChain': true,
      },
      helperStatus: _helperStatus(
        mode: 'chain',
        connected: true,
        uptimeMs: 300000,
      ),
      dashboard: <String, dynamic>{
        'status': 'Started',
        'selectedProfileId': 12,
        'modes': ['rule', 'global', 'direct'],
        'mode': 'rule',
        'systemProxyAvailable': false,
        'systemProxy': false,
      },
      calls: calls,
    );
    await _pumpDashboard(tester, channel, host);
    final card = find.byType(ConnectionPanel);
    expect(card, findsOneWidget);
    // The old separate chain switch is gone.
    expect(find.text('Chain with Psiphon'), findsNothing);
    // The chain is up and the route proved itself.
    expect(
      find.descendant(of: card, matching: find.text('Connected')),
      findsOneWidget,
    );
    expect(_segmentSelected(tester, 'Chained'), isTrue);

    await tester.tap(find.text('Psiphon'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    // The old helper was stopped before the new profile was selected.
    final stopAt = calls.indexWhere((c) => c.method == 'aether.stop');
    final selectAt = calls.indexWhere((c) => c.method == 'profiles.select');
    expect(stopAt, isNot(-1), reason: 'the switch must stop the old helper');
    expect(selectAt, isNot(-1), reason: 'the switch must select the new profile');
    expect(stopAt, lessThan(selectAt),
        reason: 'stop must come before select, or the old tunnel keeps running');
    // The card follows the switch: Psiphon is the mode now.
    expect(_segmentSelected(tester, 'Psiphon'), isTrue);
    expect(_segmentSelected(tester, 'Chained'), isFalse);
    expect(
      find.descendant(of: card, matching: find.text('Switch to Psiphon')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final (mode, showsPicker) in [
    ('aether', false),
    ('psiphon', true),
    ('chain', true),
  ]) {
    testWidgets(
      'country picker is ${showsPicker ? 'shown' : 'hidden'} for $mode mode',
      (tester) async {
        reportFlutterErrors();
        final channel = MethodChannel('test.connection-country-$mode');
        final host = _MockHost(
          preferences: <String, dynamic>{
            'locale': 'en',
            'helperMode': mode,
            'helperStartWith': 'new',
          },
          helperStatus: _helperStatus(mode: mode, region: mode == 'chain' ? 'DE' : ''),
          dashboard: <String, dynamic>{
            'status': 'Stopped',
            'selectedProfileId': 1,
            'modes': ['rule', 'global', 'direct'],
            'mode': 'rule',
            'systemProxyAvailable': false,
            'systemProxy': false,
          },
          calls: <MethodCall>[],
        );
        await _pumpDashboard(tester, channel, host);
        final card = find.byType(ConnectionPanel);
        expect(
          find.descendant(of: card, matching: find.text('Exit country')),
          showsPicker ? findsOneWidget : findsNothing,
        );
        if (mode == 'chain') {
          expect(
            find.descendant(of: card, matching: find.text('Germany')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('New/Previous IP choice is there before connecting',
      (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.connection-start-with');
    final calls = <MethodCall>[];
    final preferences = <String, dynamic>{
      'locale': 'en',
      'helperMode': 'aether',
      'helperStartWith': 'new',
    };
    final host = _MockHost(
      preferences: preferences,
      helperStatus: _helperStatus(mode: 'aether'),
      dashboard: <String, dynamic>{
        'status': 'Stopped',
        'selectedProfileId': 1,
        'modes': ['rule', 'global', 'direct'],
        'mode': 'rule',
        'systemProxyAvailable': false,
        'systemProxy': false,
      },
      calls: calls,
    );
    await _pumpDashboard(tester, channel, host);
    final card = find.byType(ConnectionPanel);
    // The choice is on the card while nothing runs yet — the old buttons
    // only appeared after a failure or a connect.
    expect(
      find.descendant(of: card, matching: find.text('New IP')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Previous IP')),
      findsOneWidget,
    );
    expect(_segmentSelected(tester, 'New IP'), isTrue);

    await tester.tap(find.text('Previous IP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // The choice is stored for the next connect, and nothing restarts:
    // there is no tunnel to restart yet.
    expect(preferences['helperStartWith'], 'previous');
    expect(_segmentSelected(tester, 'Previous IP'), isTrue);
    expect(
      calls.where((c) =>
          c.method == 'aether.rescan' || c.method == 'aether.reconnect'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Connection card keeps a failed start visible', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.connection-start-failure');
    final host = _MockHost(
      preferences: <String, dynamic>{'locale': 'en', 'helperMode': 'chain'},
      helperStatus: _helperStatus(
        mode: 'chain',
        log: [
          '[2026-11-16T11:53:21.445Z INFO aether::socks] psiphon stopped before it was ready',
        ],
        lastError: _failure,
      ),
      dashboard: <String, dynamic>{
        'status': 'Stopped',
        'selectedProfileId': 12,
        'modes': ['rule', 'global', 'direct'],
        'mode': 'rule',
        'systemProxyAvailable': false,
        'systemProxy': false,
      },
      calls: <MethodCall>[],
    );
    await _pumpDashboard(tester, channel, host);
    final card = find.byType(ConnectionPanel);
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('no start failure, no failure shown', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.connection-start-failure-none');
    final host = _MockHost(
      preferences: <String, dynamic>{'locale': 'en', 'helperMode': 'aether'},
      helperStatus: _helperStatus(mode: 'aether'),
      dashboard: <String, dynamic>{
        'status': 'Stopped',
        'selectedProfileId': 1,
        'modes': ['rule', 'global', 'direct'],
        'mode': 'rule',
        'systemProxyAvailable': false,
        'systemProxy': false,
      },
      calls: <MethodCall>[],
    );
    await _pumpDashboard(tester, channel, host);
    expect(find.text("Couldn't start"), findsNothing);
    expect(find.text('Off'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('dashboard order migrates legacy Aether/Psiphon cards to Connection',
      () {
    expect(
      dashboardOrder({
        'dashboardCards': [
          'Status',
          'Aether',
          'Psiphon',
          'Network speed',
        ],
      }),
      [
        'Status',
        'Connection',
        'Network speed',
        'Outbound mode',
        'Current profile',
        'Proxy groups',
        'Memory',
        'Intranet IP',
        'Network takeover',
        'Service status',
      ],
    );
    expect(
      dashboardOrder({}),
      [
        'Status',
        'Connection',
        'Network speed',
        'Outbound mode',
        'Current profile',
        'Proxy groups',
        'Memory',
        'Intranet IP',
        'Network takeover',
        'Service status',
      ],
    );
  });
}
