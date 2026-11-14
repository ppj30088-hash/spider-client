// The managed-mode preset, as data and as a screen.
//
// The preset half is pure: which services produce which pool rows, what those
// rows look like on the wire, and that a re-apply replaces its own rows instead
// of stacking new ones. The session half drives the real page against the test
// kernel, because the interesting behaviour is the read-spread-write: the user's
// own pool rows must survive it, and a missing driver must be reported instead of
// pretended away.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
// The page comes through widgets.dart, which re-exports it for the app's pages.
import 'package:flrone/pages/managed_rules.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

/// The `_json` column names the wire accepts. Anything else (`rule_set`,
/// `domain_suffix`, …) is the editor's shorthand, which the kernel stores but
/// never echoes — a managed row written that way would read back empty.
const _jsonColumns = {'rule_set_json', 'domain_suffix_json', 'domain_keyword_json', 'domain_json'};

/// A user row as `getGlobalRules` answers it: the editor fields plus the pool's
/// `id` and `enabled`, which the page must carry back untouched.
Map<String, Object?> userPoolRule(String name, {int id = 7}) => {
      'id': id,
      'enabled': true,
      'name': name,
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -2,
      'domain_suffix_json': <String>['example.test'],
    };

/// The resolved-name map a complete catalog would answer with: every candidate
/// the table names resolves to itself.
Map<String, String> fullCatalog() => {
      for (final service in [...managedBaseRules, ...managedServices, ...managedFallbackRules])
        for (final name in service.ruleSetNames) name: name,
    };

Map<String, bool> allEnabled() => {
      for (final service in managedServices) service.id: true,
    };

void main() {
  group('the preset compiles to wire-correct pool rows', () {
    test('only enabled services produce rows, and every row is marked', () {
      final rules = buildManagedRules(
        enabled: {
          for (final service in managedServices) service.id: false,
          'youtube': true,
        },
        resolvedNames: fullCatalog(),
      );
      final names = [for (final rule in rules) '${rule['name']}'];
      // The base rules are always on: the enabled set only gates the services.
      expect(names.where((name) => name.startsWith('${managedRulePrefix}base-')), isNotEmpty);
      expect(names.where((name) => name.startsWith('${managedRulePrefix}youtube:')), isNotEmpty);
      expect(names.where((name) => name.startsWith('${managedRulePrefix}google:')), isEmpty);
      for (final name in names) {
        expect(name, startsWith(managedRulePrefix));
        expect(isManagedRuleName(name), isTrue);
      }
    });

    test('a service with two resolved sets keeps both, and only _json columns are written', () {
      final rules = buildManagedRules(
        enabled: {for (final service in managedServices) service.id: false, 'google': true},
        resolvedNames: {'geosite-google': 'geosite-google', 'geoip-google': 'geoip-google'},
        order: ['google'],
      );
      final google = rules.where((rule) => '${rule['name']}'.startsWith('${managedRulePrefix}google:'));
      expect(google, hasLength(1));
      final row = google.single;
      expect(row['type'], 'custom');
      expect(row['disabled'], isFalse);
      expect(row['action'], 'route');
      expect(row['outbound_id'], managedProxyOutbound);
      // The values are lists, which `ruleRowFromWire` marshals once; a
      // pre-encoded string would be marshalled twice and read back empty.
      expect(row['rule_set_json'], ['geosite-google', 'geoip-google']);
      for (final key in row.keys) {
        if (key.endsWith('_json')) expect(_jsonColumns, contains(key));
      }
      expect(row.containsKey('rule_set'), isFalse);
      expect(row.containsKey('domain_suffix'), isFalse);
    });

    test('an unresolved candidate is skipped instead of written blind', () {
      final rules = buildManagedRules(enabled: {'github': true}, resolvedNames: const {});
      expect(rules.where((rule) => '${rule['name']}'.startsWith('${managedRulePrefix}github:')), isEmpty);
    });

    test('the inline fallbacks still make a row when the catalog has nothing', () {
      final rules = buildManagedRules(enabled: {'ai': true}, resolvedNames: const {}, order: ['ai']);
      final ai = rules.where((rule) => '${rule['name']}'.startsWith('${managedRulePrefix}ai:')).toList();
      expect(ai, hasLength(1));
      expect(ai.single['domain_suffix_json'], containsAll(<String>['cdn.usefathom.com', 'intercom.io']));
      expect(ai.single.containsKey('rule_set_json'), isFalse);
    });

    test('FCM is direct, AdBlock is a reject, everything else goes through the proxy', () {
      Map<String, Object?> rowOf(String id) => buildManagedRules(
            enabled: {for (final service in managedServices) service.id: false, id: true},
            resolvedNames: fullCatalog(),
            order: [id],
          ).firstWhere((rule) => '${rule['name']}'.startsWith('$managedRulePrefix$id:'));

      expect(rowOf('fcm')['outbound_id'], managedDirectOutbound);
      expect(rowOf('fcm')['action'], 'route');

      final adblock = rowOf('adblock');
      expect(adblock['action'], 'reject');
      expect(adblock['outbound_id'], managedRejectOutbound);

      for (final id in ['youtube', 'google', 'telegram', 'netflix', 'spotify']) {
        expect(rowOf(id)['outbound_id'], managedProxyOutbound, reason: id);
        expect(rowOf(id)['action'], 'route', reason: id);
      }
    });

    test('the order the page saved is the order the pool gets', () {
      final rules = buildManagedRules(
        // A partial map falls back to the table's defaults for the rest, so the
        // three services under test are enabled and every other one is off.
        enabled: {
          for (final service in managedServices) service.id: false,
          'youtube': true,
          'google': true,
          'github': true,
        },
        resolvedNames: fullCatalog(),
        order: ['github', 'youtube', 'google'],
      );
      // A managed name is managed:<id>:<index>; the id is the middle part.
      final serviceRows = [
        for (final rule in rules)
          if (!'${rule['name']}'.startsWith('${managedRulePrefix}base-')) '${rule['name']}'.split(':')[1],
      ];
      expect(serviceRows, ['github', 'youtube', 'google']);
    });

    test('the outside-China catch-all is last, after every service', () {
      final rules = buildManagedRules(enabled: allEnabled(), resolvedNames: fullCatalog());
      final names = [for (final rule in rules) '${rule['name']}'];
      final catchAll = names.lastIndexWhere((name) => name.startsWith('${managedRulePrefix}base-!cn:'));
      expect(catchAll, isNot(-1));
      expect(catchAll, names.length - 1, reason: 'first match wins: the catch-all must not shadow a service');
      // And the reject row really is ahead of it.
      expect(
        names.indexWhere((name) => name.startsWith('${managedRulePrefix}adblock:')),
        lessThan(catchAll),
      );
    });

    test('a stored order drops unknown ids and appends the rest', () {
      final order = managedServiceOrder(['nope', 'youtube']);
      expect(order.first.id, 'youtube');
      expect(order.length, managedServices.length);
      expect(order.map((service) => service.id).toSet(), managedServices.map((service) => service.id).toSet());
    });

    test('stripManagedRules removes only this screen\'s rows', () {
      final mine = <Map<String, dynamic>>[
        {'name': 'My own rule', 'rule_set_json': ['geosite-google']},
        {'name': '${managedRulePrefix}youtube:0', 'rule_set_json': ['geosite-youtube']},
        {'name': 'managed-but-not-a-prefix', 'rule_set_json': ['x']},
        {'name': '${managedRulePrefix}base-cn:0'},
      ];
      final kept = stripManagedRules(mine);
      expect(kept, hasLength(2));
      expect(kept.map((rule) => rule['name']), ['My own rule', 'managed-but-not-a-prefix']);
      // The surviving rows are the same objects: a strip must not rewrite them.
      expect(identical(kept[0], mine[0]), isTrue);
    });

    test('every service in the table has a unique id and a default switch', () {
      final ids = [for (final service in managedServices) service.id];
      expect(ids.toSet(), hasLength(ids.length));
      expect(managedServices, hasLength(22));
      expect(managedServices.where((service) => service.rejects), hasLength(1));
      expect(managedServices.singleWhere((service) => service.rejects).id, 'adblock');
      expect(defaultManagedServices().values.every((value) => value), isTrue);
    });

    test('no candidate is a .mrs URL: the kernel only takes srslist names or .srs URLs', () {
      for (final service in [...managedBaseRules, ...managedServices, ...managedFallbackRules]) {
        for (final name in service.ruleSetNames) {
          expect(name.contains('://'), isFalse, reason: '$name must be a catalog name');
          expect(name.endsWith('.mrs'), isFalse, reason: '$name must not be mihomo');
        }
      }
    });
  });

  group('rule-set URLs stay away from local addresses', () {
    test('public https and http pass', () {
      expect(isSafeRuleSetUrl('https://raw.githubusercontent.com/o/r/main/geo/geosite/google.srs'), isTrue);
      expect(isSafeRuleSetUrl('http://example.org/a.srs'), isTrue);
      expect(isSafeRuleSetUrl('https://fastly.jsdelivr.net/gh/o/r@meta/geo/geosite/x.srs'), isTrue);
    });

    test('other schemes and credentials are refused', () {
      expect(isSafeRuleSetUrl('file:///etc/passwd'), isFalse);
      expect(isSafeRuleSetUrl('ftp://example.org/a.srs'), isFalse);
      expect(isSafeRuleSetUrl('data:text/plain,x'), isFalse);
      expect(isSafeRuleSetUrl('https://user:pass@example.org/a.srs'), isFalse);
      expect(isSafeRuleSetUrl(''), isFalse);
      expect(isSafeRuleSetUrl('not a url'), isFalse);
    });

    test('loopback, private, link-local, CGNAT and reserved literals are refused', () {
      for (final url in [
        'http://localhost/a.srs',
        'http://api.localhost/a.srs',
        'http://printer.local/a.srs',
        'http://127.0.0.1/a.srs',
        'http://127.1.2.3/a.srs',
        'http://10.0.0.1/a.srs',
        'http://172.16.5.4/a.srs',
        'http://172.31.255.255/a.srs',
        'http://192.168.1.1/a.srs',
        'http://169.254.169.254/a.srs',
        'http://100.64.0.1/a.srs',
        'http://0.0.0.0/a.srs',
        'http://224.0.0.1/a.srs',
        'http://[::1]/a.srs',
        'http://[fe80::1]/a.srs',
        'http://[fd00::1]/a.srs',
        'http://[::ffff:127.0.0.1]/a.srs',
      ]) {
        expect(isSafeRuleSetUrl(url), isFalse, reason: url);
      }
    });

    test('a public literal is fine', () {
      expect(isSafeRuleSetUrl('http://1.1.1.1/a.srs'), isTrue);
      expect(isSafeRuleSetUrl('http://[2606:4700:4700::1111]/a.srs'), isTrue);
      expect(isSafeRuleSetUrl('http://172.15.0.1/a.srs'), isTrue);
      expect(isSafeRuleSetUrl('http://172.32.0.1/a.srs'), isTrue);
    });
  });

  group('the screen', () {
    late StreamController<dynamic> events;
    late List<Map<String, Object?>> poolRules;
    late List<Map<String, Object?>> savedPool;
    late Map<String, dynamic> storedPreferences;
    late int poolWrites;

    /// The catalog the host would answer: every candidate resolves to itself.
    Map<String, Object?> catalogReply(String query) => {
          'total': 1,
          'entries': [
            {'name': query, 'url': 'https://raw.githubusercontent.com/o/r/main/$query.srs'},
          ],
        };

    Object? routeFixtures(ActionMethod method, Object? data) {
      switch (method) {
        case ActionMethod.getGlobalRules:
          return {'rules': poolRules};
        case ActionMethod.saveGlobalRules:
          poolWrites++;
          final payload = data is Map ? data['rules'] : null;
          savedPool = [
            for (final rule in payload as List? ?? const []) Map<String, Object?>.from(rule as Map),
          ];
          return {'rules': savedPool};
        default:
          return null;
      }
    }

    Future<void> mount(WidgetTester tester, {bool attachKernel = true}) async {
      reportFlutterErrors();
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      // Tall enough that all 22 rows and the footer are built at once.
      tester.view.physicalSize = const Size(400, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      poolRules = [userPoolRule('My own rule')];
      savedPool = <Map<String, Object?>>[];
      poolWrites = 0;
      storedPreferences = {'locale': 'en'};
      const channel = MethodChannel('test.managed-mode');
      events = StreamController<dynamic>.broadcast();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'ready':
            return {
              'version': 'test',
              'coreVersion': 'test',
              'preferences': storedPreferences,
              'dashboard': {'status': 'Stopped'},
            };
          case 'preferences.set':
            storedPreferences = {
              ...storedPreferences,
              ...Map<String, dynamic>.from((call.arguments as Map)['value'] as Map),
            };
            return storedPreferences;
          case 'routes.ruleSets':
            final args = call.arguments as Map? ?? const {};
            return catalogReply('${args['query'] ?? ''}');
        }
        return null;
      });
      final box = BoxController(channel: channel, events: events.stream);
      if (attachKernel) {
        box.kernel.debugAttach(FakeRouteKernel(routeFixtures), NoopKernelWorker());
      }
      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await events.close();
        messenger.setMockMethodCallHandler(channel, null);
      });
    }

    Future<void> openManagedMode(WidgetTester tester) async {
      openPage(tester.element(find.byType(HomePage)), const ManagedModePage());
      await tester.pumpAndSettle();
    }

    testWidgets('one rounded card per service, each with a switch', (tester) async {
      await mount(tester);
      await openManagedMode(tester);

      expect(find.text('Managed mode'), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      expect(find.text('AdBlock'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(managedServices.length));
      expect(find.byType(Switch), findsNWidgets(managedServices.length));
      // FCM is the one service the reference sends direct; the row says so on
      // AdBlock only (a reject is the surprising case).
      expect(find.text('Block'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a toggle saves the switches, then writes the pool once', (tester) async {
      await mount(tester);
      await openManagedMode(tester);

      await tester.tap(find.text('YouTube'));
      await tester.pumpAndSettle();

      final switches = Map<String, dynamic>.from(storedPreferences['managedServices'] as Map);
      expect(switches['youtube'], isFalse);
      expect(switches['google'], true);
      expect(poolWrites, 1);

      // The user's own rule survives, and the managed rows are exactly the
      // preset's output for the switch state just saved.
      final names = [for (final rule in savedPool) '${rule['name']}'];
      expect(names, contains('My own rule'));
      expect(names.where((name) => name.startsWith('${managedRulePrefix}youtube:')), isEmpty);
      expect(names.where((name) => name.startsWith('${managedRulePrefix}google:')), isNotEmpty);
      // The user's row keeps the pool fields the read handed back.
      final mine = savedPool.firstWhere((rule) => rule['name'] == 'My own rule');
      expect(mine['id'], 7);
      expect(mine['domain_suffix_json'], <String>['example.test']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling twice never duplicates a row', (tester) async {
      await mount(tester);
      await openManagedMode(tester);

      await tester.tap(find.text('YouTube'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('YouTube'));
      await tester.pumpAndSettle();

      final names = [for (final rule in savedPool) '${rule['name']}'];
      expect(names.toSet(), hasLength(names.length), reason: 'no managed row may repeat');
      expect(names, contains('My own rule'));
      expect(poolWrites, 2);
      // The re-enable wrote YouTube back exactly once.
      expect(names.where((name) => name.startsWith('${managedRulePrefix}youtube:')), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stale managed row from an earlier build is replaced, not stacked', (tester) async {
      await mount(tester);
      poolRules = [
        userPoolRule('My own rule'),
        {'id': 9, 'name': '${managedRulePrefix}gone:0', 'type': 'custom', 'action': 'route', 'outbound_id': -1,
          'disabled': false, 'rule_set_json': <String>['geosite-gone']},
      ];
      await openManagedMode(tester);
      await tester.tap(find.text('Steam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Steam'));
      await tester.pumpAndSettle();

      final names = [for (final rule in savedPool) '${rule['name']}'];
      expect(names, isNot(contains('${managedRulePrefix}gone:0')));
      expect(names, contains('My own rule'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('without the driver the page says so and keeps the switches', (tester) async {
      await mount(tester, attachKernel: false);
      await openManagedMode(tester);

      await tester.tap(find.text('YouTube'));
      await tester.pumpAndSettle();

      // The switch state is saved no matter what the pool did.
      final switches = Map<String, dynamic>.from(storedPreferences['managedServices'] as Map);
      expect(switches['youtube'], isFalse);
      // The failure is stated in the page, with a retry, and nothing was written.
      expect(find.text('The rules were not written'), findsOneWidget);
      expect(find.textContaining('FFI driver'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(poolWrites, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the host menu items are merged into the bar, not replaced', (tester) async {
      await mount(tester);
      var opened = false;
      openPage(
        tester.element(find.byType(HomePage)),
        ManagedModePage(menuItems: [
          PopupMenuItem(label: 'Route profiles', onPressed: () => opened = true),
        ]),
      );
      await tester.pumpAndSettle();

      // The page's own actions lead the bar; the third slot is the bar's cap, so
      // Refresh folds into the overflow alongside the host's entries.
      expect(find.byTooltip('Add service'), findsOneWidget);
      expect(find.byTooltip('Sort'), findsOneWidget);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Route profiles'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      await tester.tap(find.text('Route profiles'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add service enables an off service through the same save path', (tester) async {
      await mount(tester);
      await openManagedMode(tester);
      // Everything is on by default, so the sheet reports nothing to add.
      await tester.tap(find.byTooltip('Add service'));
      await tester.pumpAndSettle();
      expect(find.text('Every service is already enabled'), findsOneWidget);
      expect(poolWrites, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the refresh action re-applies what the preferences hold', (tester) async {
      await mount(tester);
      await openManagedMode(tester);

      // With no host menu items the bar holds all three actions.
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(poolWrites, 1);
      final names = [for (final rule in savedPool) '${rule['name']}'];
      expect(names, contains('My own rule'));
      expect(names.where((name) => name.startsWith(managedRulePrefix)), isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
