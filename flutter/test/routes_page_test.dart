// The route-profile page: a card per route profile, the shared rule pool one
// level down behind the overflow menu, and a profile's own rules on a page of
// their own.
//
// The Routing screen itself is the managed-mode service list now, so the cards
// moved one step in to RouteProfilesPage; every assertion below is kept as it
// was, retargeted at that page.
//
// The pool assertions that used to be this page's are kept verbatim on the pool
// page: nothing the Routing page could do before was dropped, it moved.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

Map<String, Object?> poolRule(String name, {int id = 1}) => {
      'id': id,
      'name': name,
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -1,
      'domain_suffix': <String>['example.test'],
    };

Map<String, Object?> profileRule(String name, {int disabled = 0}) => {
      'name': name,
      'type': 'custom',
      'disabled': disabled != 0,
      'action': 'route',
      'outbound_id': -2,
      'domain': <String>['example.test'],
    };

Map<String, Object?> profile(
  String name, {
  int id = 1,
  bool current = false,
  bool isRemote = false,
  bool isRaw = false,
  int ruleCount = 3,
  String defaultOutbound = 'proxy',
}) => {
      'id': id,
      'name': name,
      'defaultOutbound': defaultOutbound,
      'current': current,
      'isRemote': isRemote,
      'isRaw': isRaw,
      'ruleCount': ruleCount,
      'simpleRuleCount': 0,
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> poolRules;
  late List<Map<String, Object?>> savedPool;
  late List<Map<String, Object?>> profiles;
  late Map<int, List<Map<String, Object?>>> profileRules;
  late int currentId;
  late List<Map<String, Object?>> savedProfileRules;
  late int savedProfileId;

  Map<String, Object?>? routeFixtures(ActionMethod method, Object? data) {
    switch (method) {
      case ActionMethod.getRouteProfiles:
        return {'currentId': currentId, 'profiles': profiles};
      case ActionMethod.getRouteRules:
        final id = (data is Map ? data['id'] as num? : null)?.toInt() ?? 0;
        return {'rules': profileRules[id] ?? const []};
      case ActionMethod.saveRouteRules:
        final payload = data is Map ? data : const {};
        savedProfileId = (payload['id'] as num?)?.toInt() ?? 0;
        savedProfileRules = [
          for (final rule in payload['rules'] as List? ?? const [])
            Map<String, Object?>.from(rule as Map),
        ];
        profileRules[savedProfileId] = savedProfileRules;
        return {'rules': savedProfileRules};
      case ActionMethod.getGlobalRules:
        return {'rules': poolRules};
      case ActionMethod.saveGlobalRules:
        final payload = data is Map ? data['rules'] : null;
        savedPool = [
          for (final rule in payload as List? ?? const [])
            Map<String, Object?>.from(rule as Map),
        ];
        poolRules = savedPool;
        return {'rules': savedPool};
      case ActionMethod.deleteGlobalRule:
        return null;
      default:
        return null;
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    List<Map<String, Object?>>? pool,
    List<Map<String, Object?>>? routeProfiles,
    bool attachKernel = true,
  }) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    poolRules = pool ?? [poolRule('Pool A')];
    savedPool = <Map<String, Object?>>[];
    profiles = routeProfiles ?? [profile('Default profile', current: true)];
    currentId = 1;
    profileRules = {
      1: [profileRule('Route DNS')],
      2: [profileRule('Pinned LAN')],
    };
    savedProfileRules = <Map<String, Object?>>[];
    savedProfileId = 0;
    const channel = MethodChannel('test.routes-page');
    events = StreamController<dynamic>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'groups.nodes':
          return {
            'nodes': [
              {'id': 10, 'tag': 'Node A'},
            ],
          };
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

  /// The cards live on their own page now: the Routing screen opens the
  /// managed service list, and its ⋮ menu is the way to the profile cards.
  Future<void> openRouting(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const RouteProfilesPage());
    await tester.pumpAndSettle();
  }

  /// The pool lives behind ⋮ → Global rules now.
  Future<void> openPool(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global rules'));
    await tester.pumpAndSettle();
  }

  /// The Routing screen's own overflow, once it is on screen.
  Future<void> openRoutingMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
  }

  group('the routing screen is the managed service list', () {
    testWidgets('its primary view is the service switches', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)), const RoutingPage());
      await tester.pumpAndSettle();

      expect(find.byType(ManagedModePage), findsOneWidget);
      // The screenshot's shape: a switch per service, not the profile cards.
      expect(find.byType(RouteProfilesPage), findsNothing);
      expect(find.text('Google'), findsWidgets);
      expect(find.text('Telegram'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the overflow still reaches profiles, pool and engine settings', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)), const RoutingPage());
      await tester.pumpAndSettle();
      await openRoutingMenu(tester);

      expect(find.text('Route profiles'), findsOneWidget);
      expect(find.text('Global rules'), findsOneWidget);
      expect(find.text('Route settings'), findsOneWidget);
      expect(find.text('Automatic updates'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the profiles entry opens the card list', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)), const RoutingPage());
      await tester.pumpAndSettle();
      await openRoutingMenu(tester);
      await tester.tap(find.text('Route profiles'));
      await tester.pumpAndSettle();

      expect(find.byType(RouteProfilesPage), findsOneWidget);
      expect(find.text('Default profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pool entry opens the global rules page', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)), const RoutingPage());
      await tester.pumpAndSettle();
      await openRoutingMenu(tester);
      await tester.tap(find.text('Global rules'));
      await tester.pumpAndSettle();

      expect(find.byType(GlobalRulesPage), findsOneWidget);
      expect(find.text('Pool A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the engine entries open their settings pages', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)), const RoutingPage());
      await tester.pumpAndSettle();

      await openRoutingMenu(tester);
      await tester.tap(find.text('Route settings'));
      await tester.pumpAndSettle();
      expect(find.text('Outbound domain strategy'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openRoutingMenu(tester);
      await tester.tap(find.text('Automatic updates'));
      await tester.pumpAndSettle();
      expect(find.text('Update rule sets'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the route-profile page is the card list', () {
    testWidgets('a card per profile, with the current one badged', (tester) async {
      reportFlutterErrors();
      await mount(tester, routeProfiles: [
        profile('Default profile', current: true),
        profile('Bypass LAN', id: 2, ruleCount: 4, defaultOutbound: 'direct'),
      ]);
      await openRouting(tester);

      expect(find.text('Default profile'), findsOneWidget);
      expect(find.text('Bypass LAN'), findsOneWidget);
      // Throne's summary line, one per card.
      expect(find.text('Default: proxy · 3 rules'), findsOneWidget);
      expect(find.text('Default: direct · 4 rules'), findsOneWidget);
      expect(find.byType(SelectionBadge), findsOneWidget);
      expect(find.byTooltip('Edit rule'), findsNWidgets(2));
      // Each card carries the reference's pencil + ⋮ pair, and the card's own
      // menu tooltip is distinct from the bar's.
      expect(find.byTooltip('Action'), findsNWidgets(2));
      expect(find.byTooltip('More'), findsOneWidget);
      // The rule list is not on this page any more, and neither is its search.
      expect(find.byTooltip('Add rule'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a card menu offers only what the kernel can back', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action').first);
      await tester.pumpAndSettle();
      expect(find.text('Edit rules'), findsOneWidget);
      expect(find.text('Global rules'), findsOneWidget);
      // No delete / clone / update: none of them has a kernel action.
      expect(find.text('Clone'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Update'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the remote and read-only markers show up on the card', (tester) async {
      reportFlutterErrors();
      await mount(tester, routeProfiles: [
        profile('Subscribed', id: 2, isRemote: true),
        profile('Imported', id: 3, isRaw: true),
      ]);
      await openRouting(tester);

      expect(find.text('Remote'), findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty profile list says so instead of spinning', (tester) async {
      reportFlutterErrors();
      await mount(tester, routeProfiles: []);
      await openRouting(tester);

      expect(find.text('No route profiles yet'), findsOneWidget);
      expect(find.byType(ActivityIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the engine switches and the pool stay in the overflow menu', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Global rules'), findsOneWidget);
      expect(find.text('Route settings'), findsOneWidget);
      expect(find.text('Automatic updates'), findsOneWidget);
      // No dead controls: profile CRUD has no kernel action behind it.
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Clone'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a card tap opens that profile\'s rules', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.text('Default profile'));
      await tester.pumpAndSettle();

      expect(find.byType(RouteRulesPage), findsOneWidget);
      expect(find.text('Route DNS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pencil opens the same rule list as the card', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Edit rule'));
      await tester.pumpAndSettle();

      // One page, not two: the card's own press must not fire under the button.
      expect(find.byType(RouteRulesPage), findsOneWidget);
      expect(find.text('Route DNS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the refresh action re-reads the list', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      expect(find.text('Default profile'), findsOneWidget);

      profiles = [profile('Renamed', current: true)];
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Renamed'), findsOneWidget);
      expect(find.text('Default profile'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the global pool page keeps everything the routing page had', () {
    testWidgets('it is the rule list with an Add rule action', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      await openPool(tester);

      expect(find.text('Pool A'), findsOneWidget);
      expect(find.byTooltip('Add rule'), findsOneWidget);
      expect(find.byTooltip('Import rules from JSON'), findsNothing);
      expect(find.text('Per-profile rules'), findsNothing);
      expect(find.text('Restore defaults'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add rule opens the built-in type picker', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      await openPool(tester);

      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();

      expect(find.text('Rule type'), findsWidgets);
      expect(find.text('Target'), findsWidgets);
      expect(find.text(ruleKinds.first.label), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the type picker offers all 33 built-in FlClash types', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      await openPool(tester);
      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rule type').last);
      await tester.pumpAndSettle();

      for (final kind in ruleKinds) {
        expect(find.text(kind.label), findsWidgets, reason: '${kind.label} must be offered');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding a rule writes it to the pool', (tester) async {
      reportFlutterErrors();
      await mount(tester, pool: []);
      await openRouting(tester);
      await openPool(tester);
      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();

      // The page's search field comes first, then the sheet's Name and Content.
      await tester.enterText(find.byType(TextField).at(2), 'example.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add rule').last);
      await tester.pumpAndSettle();

      expect(savedPool.length, 1);
      expect(savedPool.single['domain'], ['example.test']);
      expect(savedPool.single['action'], 'route');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a rule without content is refused', (tester) async {
      reportFlutterErrors();
      await mount(tester, pool: []);
      await openRouting(tester);
      await openPool(tester);
      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add rule').last);
      await tester.pumpAndSettle();

      expect(find.text('Content is required'), findsOneWidget);
      expect(savedPool, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the search field filters the pool', (tester) async {
      reportFlutterErrors();
      await mount(tester, pool: [poolRule('Keep me'), poolRule('Hide me', id: 2)]);
      await openRouting(tester);
      await openPool(tester);

      expect(find.text('Keep me'), findsOneWidget);
      expect(find.text('Hide me'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Keep');
      await tester.pumpAndSettle();
      expect(find.text('Keep me'), findsOneWidget);
      expect(find.text('Hide me'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selection mode opens from the bar and can delete', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      await openPool(tester);

      expect(find.byTooltip('Delete selected'), findsNothing);
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete selected'), findsOneWidget);
      expect(find.byTooltip('Select all'), findsOneWidget);
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete selected'));
      await tester.pumpAndSettle();
      expect(find.text('Delete selected'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the rule list offers no per-profile opt-out', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      await openRouting(tester);
      await openPool(tester);

      await tester.longPress(find.text('Pool A'));
      await tester.pumpAndSettle();
      expect(find.text('Disable for a profile'), findsNothing);
      expect(find.text('Enable for a profile'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('a profile\'s own rule list', () {
    testWidgets('rows render from getRouteRules', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Default profile'));
      await tester.pumpAndSettle();

      expect(find.text('Default profile'), findsOneWidget);
      expect(find.text('Route DNS'), findsOneWidget);
      expect(find.byTooltip('Add rule'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a write sends the whole list, ids and columns included', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Default profile'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();
      // The existing row's columns must survive: only the appended rule is new.
      // No search field stands ahead of the sheet here, so Name is first.
      await tester.enterText(find.byType(TextField).at(1), 'added.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add rule').last);
      await tester.pumpAndSettle();

      expect(savedProfileId, 1);
      expect(savedProfileRules.length, 2);
      expect(savedProfileRules.first['name'], 'Route DNS');
      expect(savedProfileRules.last['domain'], ['added.test']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the menu toggles the stored disabled column', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Default profile'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Route DNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();

      expect(savedProfileId, 1);
      expect(savedProfileRules.single['disabled'], isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reorder sends the list in its new order', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      profileRules[1] = [profileRule('First'), profileRule('Second')];
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Default profile'));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);

      // onReorderItem's newIndex already accounts for the removed row, so
      // moving down one slot lands after the neighbour, not on it.
      final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      list.onReorderItem!(0, 1);
      await tester.pumpAndSettle();

      expect(savedProfileRules.map((rule) => rule['name']), ['Second', 'First']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without the FFI driver the page states the reason', (tester) async {
      reportFlutterErrors();
      await mount(tester, attachKernel: false);
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Default profile'));
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
      expect(find.textContaining('FFI driver'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a read-only profile offers no editing control', (tester) async {
      reportFlutterErrors();
      await mount(tester);
      openPage(tester.element(find.byType(HomePage)),
          const RouteRulesPage(id: 1, name: 'Imported', readOnly: true));
      await tester.pumpAndSettle();

      expect(find.text('Route DNS'), findsOneWidget);
      expect(find.byTooltip('Add rule'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the built-in list carries the 33 FlClash rule types', (tester) async {
    expect(ruleKinds.length, 33);
    expect(ruleKinds.map((kind) => kind.label).toSet().length, 33);
  });
}
