// The smooth open: the app launches on the spider over black and the
// dashboard cards ease in on the first frame — no white flash, no hard
// cut, and no added waiting.
import 'dart:async';

import 'package:flrone/components/dashboard_entrance.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

/// The entrance fade is the first Opacity below the entrance widget.
double _entranceOpacity(WidgetTester tester) {
  final opacity = find.descendant(
    of: find.byType(DashboardEntrance),
    matching: find.byType(Opacity),
  );
  return tester.widget<Opacity>(opacity.first).opacity;
}

Future<void> _pumpReady(
  WidgetTester tester,
  MethodChannel channel, {
  Future<Map<String, dynamic>> Function()? ready,
}) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'ready') {
      return ready != null
          ? await ready()
          : {
              'version': 'test',
              'coreVersion': 'test',
              'preferences': {'locale': 'en'},
              'profiles': [
                {'id': 1, 'name': 'Local profile', 'remote': false},
              ],
              'dashboard': {
                'status': 'Stopped',
                'selectedProfileId': 1,
                'modes': ['rule', 'global', 'direct'],
                'mode': 'rule',
                'systemProxyAvailable': false,
                'systemProxy': false,
              },
            };
    }
    if (call.method == 'aether.status' || call.method == 'psiphon.status') {
      return {
        'connected': false,
        'running': false,
        'mode': null,
        'aetherSelected': false,
        'psiphonSelected': false,
        'chainSelected': false,
        'psiphonRegion': '',
        'uptimeMs': 0,
        'startupMs': 90000,
        'log': <String>[],
        'lastError': null,
      };
    }
    if (call.method == 'dashboard.egress') {
      return {'ip': '203.0.113.1', 'country': 'CN', 'type': 'Residential'};
    }
    if (call.method == 'preferences.set') {
      return json((call.arguments as Map)['value']);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  addTearDown(events.close);
  await tester.pumpWidget(
    BoxApp(controller: BoxController(channel: channel, events: events.stream)),
  );
}

void main() {
  testWidgets('dashboard entrance starts faded and settles to full opacity',
      (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.dashboard-entrance');
    await _pumpReady(tester, channel);
    await tester.pump();
    expect(find.byType(DashboardEntrance), findsOneWidget);
    // The first frame is faded in, not already settled.
    expect(_entranceOpacity(tester), lessThan(1.0));
    // 400 ms later the 350 ms entrance is done — no wall-clock wait,
    // the fake clock advances it.
    await tester.pump(const Duration(milliseconds: 400));
    expect(_entranceOpacity(tester), 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the loading screen shows the spider, not a spinner',
      (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.loading-splash');
    final ready = Completer<Map<String, dynamic>>();
    await _pumpReady(
      tester,
      channel,
      ready: () => ready.future,
    );
    await tester.pump();
    // While the bridge answers `ready`, the app shows the spider emblem
    // on black — the same picture as the native splash — and no spinner.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            (widget.image as AssetImage?)?.assetName ==
                'assets/images/app_icon.webp',
      ),
      findsOneWidget,
    );
    expect(find.byType(ActivityIndicator), findsNothing);
    // Once ready answers, the dashboard opens with its entrance.
    ready.complete({
      'version': 'test',
      'coreVersion': 'test',
      'preferences': {'locale': 'en'},
      'profiles': [
        {'id': 1, 'name': 'Local profile', 'remote': false},
      ],
      'dashboard': {
        'status': 'Stopped',
        'selectedProfileId': 1,
        'modes': ['rule', 'global', 'direct'],
        'mode': 'rule',
        'systemProxyAvailable': false,
        'systemProxy': false,
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.byType(DashboardEntrance), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
