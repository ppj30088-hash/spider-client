// The speed screen's feed, as the host actually delivers it.
//
// The host relays `testSession` events only while `groups.testSession.visible`
// is true (ThroneBoxBridge.setTestSessionVisible), and that flag is set by a
// BoxDataSubscription over BoxData.testSession. The screen used to rely on
// `box.addListener` alone, which reads a field that never changed: a run
// started from the dashboard's Network speed card sat at Ready forever. These
// tests pin the subscription and the two verdicts the page now honours.

import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

/// One live speed snapshot in the wire shape BboxTestSession.wire emits.
Map<String, dynamic> _snapshot({
  String stage = 'download',
  bool finished = false,
  double dl = 8000000,
  double ul = 3000000,
  double ping = 42,
}) => {
  'kind': 2,
  'running': !finished,
  'speed': {
    'profileId': 7,
    'name': 'Node A',
    'stage': stage,
    'dlBps': dl,
    'ulBps': ul,
    'dlBytes': 8000000,
    'ulBytes': 3000000,
    'pingMs': ping,
    'server': 'speed.example',
    'serverCountry': 'US',
    'finished': finished,
    'samples': [
      [0, 1000, false],
      [1, 4000000, false],
      [2, dl, false],
      [3, 500000, true],
      [4, ul, true],
    ],
  },
};

void main() {
  testWidgets(
    'opening the screen subscribes to the session feed and a relayed snapshot '
    'reaches the gauge and the tiles',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.speed-feed');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {
              'status': 'Started',
              'profile': {'id': 7},
              'selectedProfileId': 7,
            },
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.testSession.start') return true;
        if (call.method == 'groups.testSession.visible') return null;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();

      // Opened the way the dashboard's Network speed card opens it.
      openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
      await tester.pumpAndSettle();

      // The page asks the host to relay the session feed. Without this call the
      // rest of this test could never pass, because the host emits nothing.
      final visible = calls
          .where((call) => call.method == 'groups.testSession.visible')
          .map((call) => json(call.arguments))
          .toList();
      expect(visible, isNotEmpty);
      expect(visible.last['visible'], isTrue);

      // A run started from here, then a snapshot relayed on the feed. This is
      // the path the dashboard's card takes; before the subscription the same
      // snapshot never arrived and the gauge stayed at Ready.
      await tester.tap(find.text('Start'));
      await tester.pump();
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump(const Duration(milliseconds: 400));

      events.add({'type': 'testSession', 'value': _snapshot()});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The stage caption and the live rate, from the same snapshot.
      expect(find.text('Download'), findsWidgets);
      expect(find.text('8.0'), findsOneWidget);
      expect(find.text('Mbps'), findsOneWidget);

      // The finished snapshot settles the run on its own numbers.
      events.add({
        'type': 'testSession',
        'value': _snapshot(
          stage: 'complete',
          finished: true,
          dl: 8000000,
          ul: 3000000,
        ),
      });
      await tester.pumpAndSettle();
      expect(find.text('Complete'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('8.00 Mbps'), findsOneWidget);
      expect(find.text('3.00 Mbps'), findsOneWidget);
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('a refused start shows the already-running verdict and Start '
      'stays usable', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.speed-feed-busy');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {
            'status': 'Started',
            'profile': {'id': 7},
            'selectedProfileId': 7,
          },
          'preferences': {'locale': 'en'},
        };
      }
      // The host's own verdict: another session already owns the tester.
      if (call.method == 'groups.testSession.start') return false;
      if (call.method == 'groups.testSession.visible') return null;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      calls.where((call) => call.method == 'groups.testSession.start'),
      hasLength(1),
    );
    expect(
      find.text('A speed test is already running'),
      findsOneWidget,
      reason: 'the false reply is a verdict, not a failure',
    );
    // The refusal left the page idle, so the button is Start again, not Stop,
    // and it can be pressed once more without the spinner having stuck.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'groups.testSession.start'),
      hasLength(2),
      reason: 'a refused run does not lock the screen',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the screen shows only the figures the kernel measures', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.speed-feed-honest');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {
            'status': 'Started',
            'profile': {'id': 7},
            'selectedProfileId': 7,
          },
          'preferences': {'locale': 'en'},
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    // No run yet, so nothing measured: the page must not advertise knobs the
    // kernel never reads (provider, protocol, duration, connection count) nor
    // figures the native run never produces (jitter, loaded latency, RPM).
    expect(find.text('Run settings'), findsNothing);
    expect(find.text('Jitter'), findsNothing);
    expect(find.text('Loaded latency'), findsNothing);
    expect(find.text('RPM'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('Delay'), findsWidgets);
    expect(find.text('Download'), findsWidgets);
    expect(find.text('Upload'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
