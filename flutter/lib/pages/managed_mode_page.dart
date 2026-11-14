// The managed-mode screen: one switch per service, on a scrollable list of
// rounded rows (the reference app's shape), backed by an embedded preset of
// route rules in the shared global pool.
//
// What a switch does
// ------------------
// The switch state lives in the preferences (`managedServices`), so it survives
// a restart even when no kernel is running. Saving it then recompiles the whole
// preset into the pool: read `getGlobalRules`, drop this screen's own rows
// (`managed:` prefix), append the enabled services, write the array back. That
// is the same read-spread-write the JSON importer uses (rule_import.dart:37-47),
// and it is idempotent: a second save rewrites the same rows instead of adding
// them again.
//
// Without the kernel there is no pool to write: `routeGlobalRules` throws a
// StateError ("the route store needs the FFI driver; start the VPN first"). The
// page says so plainly and keeps the switch state, which is applied the next time
// a save runs with the driver attached. It never claims a write it did not make.

import 'dart:async';

import '../widgets.dart';
import 'managed_rules.dart';

/// The managed-mode service list.
///
/// [menuItems] lets the host add its own overflow entries (route profiles, the
/// shared pool, the engine settings) without this page having to know about
/// them; they are merged before the page's own entries.
class ManagedModePage extends StatefulWidget {
  const ManagedModePage({super.key, this.menuItems = const <PopupMenuItem>[]});

  /// Entries the host contributes to the ⋮ menu, shown before this page's own.
  final List<PopupMenuItem> menuItems;

  @override
  State<ManagedModePage> createState() => _ManagedModePageState();
}

/// The preference key the switches are stored under, as one object of
/// service id → bool.
const String managedServicesPreference = 'managedServices';

/// The preference key the service order is stored under, as a list of ids: the
/// pool's rule order is what decides which service wins a shared domain.
const String managedOrderPreference = 'managedServiceOrder';

class _ManagedModePageState extends State<ManagedModePage> {
  /// The switches; loaded from the preferences on the first frame and mapped
  /// onto the table's defaults for anything never touched.
  Map<String, bool> _enabled = defaultManagedServices();

  /// The service order the list draws and the pool follows (first match wins).
  List<ManagedService> _order = managedServices;

  /// True while a toggle's pool write is in flight; a second one queues behind
  /// it rather than racing the read-spread-write.
  bool _applying = false;

  /// Set when an apply is asked for while one runs: the read-spread-write is not
  /// reentrant, and skipping the request would leave the pool showing an older
  /// switch state than the preferences.
  bool _queued = false;

  /// Why the last apply failed, or null. The rows stay usable: the switches are
  /// already saved, and Retry re-runs the pool write.
  String? _error;

  /// The last apply's outcome, shown as a footer line: the managed rule count
  /// the pool now carries.
  int? _appliedCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Reads the saved switches and order. A save that never reached the pool
  /// leaves the preference set, so this is also what makes the next launch pick
  /// it up.
  void _load() {
    if (!mounted) return;
    final prefs = context.box.preferences;
    final stored = prefs[managedServicesPreference];
    final enabled = defaultManagedServices();
    if (stored is Map) {
      for (final entry in stored.entries) {
        final id = '${entry.key}';
        if (enabled.containsKey(id) && entry.value is bool) enabled[id] = entry.value as bool;
      }
    }
    final order = <String>[
      for (final id in (prefs[managedOrderPreference] as List?) ?? const []) '$id',
    ];
    setState(() {
      _enabled = enabled;
      _order = managedServiceOrder(order);
    });
  }

  /// Persists the switches, then reconciles the pool.
  ///
  /// The preference write happens first and on its own: it cannot fail for lack
  /// of a kernel, and the switch the user just moved must not snap back.
  Future<void> _setEnabled(String id, bool value) async {
    if (_enabled[id] == value) return;
    final box = context.box;
    setState(() {
      _enabled = {..._enabled, id: value};
      _error = null;
    });
    final saved = await box.setPreference(managedServicesPreference, _enabled);
    if (!mounted) return;
    if (!saved) {
      setState(() => _error = context.tr('The switch could not be saved'));
      return;
    }
    await _apply();
  }

  /// Recompiles every enabled service into the shared pool.
  ///
  /// Runs one at a time: the read-spread-write below is not reentrant, and two
  /// overlapping applies would each append the rows the other stripped. A request
  /// that arrives mid-run is remembered and replayed once, so the pool always ends
  /// up matching the switches that were last saved.
  Future<void> _apply() async {
    if (_applying) {
      _queued = true;
      return;
    }
    final box = context.box;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final names = await _resolveCatalog(box);
      final existing = json(await box.routeGlobalRules(0));
      final rules = [
        ...stripManagedRules([for (final rule in rows(existing['rules'])) Map<String, dynamic>.of(rule)]),
        ...buildManagedRules(
          enabled: _enabled,
          resolvedNames: names,
          order: [for (final service in _order) service.id],
        ),
      ];
      await box.routeSaveGlobalRules(rules);
      if (!mounted) return;
      setState(() {
        _applying = false;
        // The managed rows are whatever the strip pass left alone.
        _appliedCount = rules.length - stripManagedRules(rules).length;
      });
      // A service the catalog cannot resolve writes no rule at all. Saying so
      // matters: an enabled switch that silently does nothing reads as a rule
      // that failed to apply, and the user would look in the pool for a row
      // this build never wrote.
      final missing = [
        for (final service in _order)
          if ((_enabled[service.id] ?? service.defaultEnabled) &&
              !service.hasInlineConditions &&
              !service.ruleSetNames.any(names.containsKey))
            service.name,
      ];
      if (missing.isNotEmpty && mounted) {
        showAppBanner(
          context,
          '${context.tr('No rule set for')}: ${missing.join(', ')}',
          level: BannerLevel.warning,
        );
      }
    } catch (error) {
      if (!mounted) return;
      // A missing driver is a precondition, not a transient failure: it is said
      // in the page (with Retry) rather than in a banner that scrolls away, and
      // the switch state stays saved for the next run.
      setState(() {
        _applying = false;
        _error = BoxController.describe(error);
      });
    } finally {
      // A switch flipped while the previous write was in flight: replay it once
      // so the pool ends up matching the last saved state instead of the one the
      // earlier run happened to read. A failed run does not replay — the error
      // card already offers Retry, and looping would only repeat the failure.
      if (mounted && _queued && _error == null) {
        _queued = false;
        unawaited(_apply());
      } else {
        _queued = false;
      }
    }
  }

  /// Resolves the table's candidate catalog names against the installed
  /// srslist, keeping only exact hits.
  ///
  /// `routes.ruleSets` searches the catalog and answers `{total, entries}`; a
  /// query may also match by prefix or substring, so the answer is filtered down
  /// to entries whose name is the candidate itself. A candidate the catalog does
  /// not know is left out of the map, and [buildManagedRules] then skips it —
  /// writing an unknown name would fail the whole config build.
  Future<Map<String, String>> _resolveCatalog(BoxController box) async {
    final candidates = <String>{
      for (final service in [...managedBaseRules, ..._order, ...managedFallbackRules])
        for (final name in service.ruleSetNames) if (name.trim().isNotEmpty) name.trim(),
    };
    final resolved = <String, String>{};
    for (final candidate in candidates) {
      final reply = json(await box.routeRuleSets(candidate, 20));
      for (final entry in rows(reply['entries'])) {
        final name = '${entry['name'] ?? ''}';
        final url = '${entry['url'] ?? ''}';
        if (name != candidate) continue;
        // The catalog is the host's data, but a rule-set URL is also a download
        // the core performs: refuse a local or private address.
        if (!isSafeRuleSetUrl(url)) continue;
        resolved[candidate] = name;
        break;
      }
    }
    return resolved;
  }

  /// The reference's "add service": turn on a service that is currently off.
  ///
  /// The list draws every service, so there is nothing hidden to reveal; what
  /// "add" usefully means here is picking one to enable, which writes the same
  /// switch a row tap does.
  Future<void> _addService() async {
    final off = [for (final service in _order) if (!(_enabled[service.id] ?? service.defaultEnabled)) service];
    if (off.isEmpty) {
      showAppBanner(context, context.tr('Every service is already enabled'));
      return;
    }
    final picked = await showOptionSheet<ManagedService>(
      context: context,
      title: context.tr('Add service'),
      options: [for (final service in off) (service, '${service.emoji}  ${service.name}')],
    );
    if (picked == null || !mounted) return;
    await _setEnabled(picked.id, true);
  }

  /// Moves a service to the front of the list.
  ///
  /// The pool is checked top to bottom and the first match wins, so this order
  /// is the routing precedence, not a cosmetic one. The order is saved beside
  /// the switches and the pool is rewritten to match.
  Future<void> _sort() async {
    if (_order.length < 2) return;
    final picked = await showOptionSheet<ManagedService>(
      context: context,
      title: context.tr('Move to the front'),
      options: [for (final service in _order) (service, '${service.emoji}  ${service.name}')],
    );
    if (picked == null || !mounted) return;
    final order = [picked, ..._order.where((service) => service != picked)];
    final saved = await context.box.setPreference(
      managedOrderPreference,
      [for (final service in order) service.id],
    );
    if (!mounted) return;
    setState(() {
      _order = order;
      if (!saved) _error = context.tr('The order could not be saved');
    });
    if (saved) await _apply();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: context.tr('Managed mode'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: context.tr('Add service'),
          onPressed: _applying ? null : _addService,
        ),
        IconButtonData(
          glyph: AppGlyphs.sort,
          tooltip: context.tr('Sort'),
          onPressed: _applying ? null : _sort,
        ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: context.tr('Refresh'),
          onPressed: _applying ? null : _reload,
        ),
      ],
      // The host's own entries come first so the page's menu never hides them;
      // this page contributes none of its own (its actions are in the bar).
      menuItems: widget.menuItems,
      body: ListView.separated(
        padding: boxPagePadding(context),
        itemCount: _order.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == _order.length) return _footer(context);
          final service = _order[index];
          return _ServiceRow(
            service: service,
            value: _enabled[service.id] ?? service.defaultEnabled,
            onChanged: _applying ? null : (value) => _setEnabled(service.id, value),
          );
        },
      ),
    );
  }

  /// Reloads the switches from the preferences and re-runs the pool write: the
  /// pool is the kernel's, so another writer (the rule editor, a restore) can
  /// have replaced this screen's rows.
  Future<void> _reload() async {
    _load();
    await _apply();
  }

  /// The status line under the list: what the last apply changed, or why it
  /// could not run.
  Widget _footer(BuildContext context) {
    final error = _error;
    if (error == null) {
      final count = _appliedCount;
      if (count == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
        child: Text(
          '${context.tr('Managed rules in the global pool')}: $count',
          style: context.listCaptionStyle,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Card(
        radius: AppCorner.lg,
        isError: true,
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(children: [
          const GlyphIcon(AppGlyphs.warning),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(context.tr('The rules were not written'), style: AppTextStyle.subheadline.of(context, emphasized: true)),
            const SizedBox(height: 4),
            Text(error, style: context.listSubtitleStyle),
            const SizedBox(height: 4),
            Text(context.tr('The switches are saved; Retry writes them once the service is running.'),
              style: context.listCaptionStyle),
          ])),
          TextButton(onPressed: _applying ? null : _apply, child: Text(context.tr('Retry'))),
        ]),
      ),
    );
  }
}

/// One service row: a rounded card holding the emoji, the name, and the switch.
/// The whole row toggles, as [ListItem.toggle] does everywhere else.
class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.service, required this.value, required this.onChanged});

  final ManagedService service;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      radius: AppCorner.xl,
      // The row's own ListItem answers the tap; the card is only its surface.
      // Without `inert` a card with no onPressed draws its content disabled.
      inert: true,
      child: ListItem.toggle(
        leading: _ServiceLeading(emoji: service.emoji),
        title: Text(service.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: service.rejects ? Text(context.tr('Block')) : null,
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// The service's mark: its emoji on a round, low-contrast well, which is what
/// stands in for the brand glyphs this app does not ship.
class _ServiceLeading extends StatelessWidget {
  const _ServiceLeading({required this.emoji});

  final String emoji;

  static const double _size = 34;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: EmojiText(emoji, style: const TextStyle(fontSize: 18)),
    );
  }
}
