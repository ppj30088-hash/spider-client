// One route profile's own rules: the list the Routing page opens when a card is
// tapped. It is the same row shape the shared pool uses (ruleName /
// ruleRowSubtitle), so a rule reads the same wherever it is listed.
//
// The write path is `routeSaveRules`: the kernel replaces the profile's rule
// rows with the whole array it is handed, so every mutation — add, edit, delete,
// disable, reorder — sends the complete list. The rows are round-tripped exactly
// as `getRouteRules` answered them (ruleRowFromWire keeps every column the wire
// carried), which is why a rule the picker cannot represent survives an edit of
// its neighbour.

import '../widgets.dart';

class RouteRulesPage extends StatefulWidget {
  const RouteRulesPage({super.key, required this.id, required this.name, this.readOnly = false});

  final int id;
  final String name;

  /// A raw profile is built in and the kernel refuses to write it. The page
  /// still lists the rules, it just offers no control that would fail.
  final bool readOnly;

  @override
  State<RouteRulesPage> createState() => _RouteRulesPageState();
}

class _RouteRulesPageState extends State<RouteRulesPage> {
  List<Json> _rules = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _editable => !widget.readOnly;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = json(await context.box.routeRules(widget.id));
      if (!mounted) return;
      setState(() {
        _rules = rows(data['rules']);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      // Without the FFI driver there is no route store to answer from; say so in
      // the page instead of reporting it as a transient failure.
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  /// The one write path: the kernel replaces this profile's rules with [rules].
  Future<void> _save(List<Json> rules) async {
    try {
      await context.box.routeSaveRules(widget.id, rules);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _add() async {
    final rule = await showRulePicker(context);
    if (rule == null || !mounted) return;
    await _save([..._rules, rule]);
  }

  Future<void> _edit(int index) async {
    final rule = await showRulePicker(context, initial: _rules[index]);
    if (rule == null || !mounted) return;
    final rules = [..._rules]..[index] = rule;
    await _save(rules);
  }

  Future<void> _delete(int index) async {
    final name = ruleName(_rules[index], index);
    final ok = await confirm(context, 'Delete this rule?', message: name, action: 'Delete');
    if (!ok || !mounted) return;
    await _save([..._rules]..removeAt(index));
  }

  /// `disabled` is a stored column, so the toggle goes through the same save.
  Future<void> _toggleDisabled(int index) async {
    final rules = [..._rules];
    rules[index] = {...rules[index], 'disabled': rules[index]['disabled'] != true};
    await _save(rules);
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final rules = [..._rules];
    rules.insert(newIndex, rules.removeAt(oldIndex));
    setState(() => _rules = rules);
    await _save(rules);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: widget.name.isEmpty ? context.tr('Route profile') : widget.name,
      iconActions: [
        if (_editable)
          IconButtonData(
            glyph: AppGlyphs.add,
            tooltip: context.tr('Add rule'),
            onPressed: _loading || _error != null ? null : _add,
          ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: context.tr('Refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: ActivityIndicator.page());
    if (_error != null) return ErrorState(_error!, retry: _load);
    if (_rules.isEmpty) {
      return NullStatus(
        label: context.tr('No rules yet'),
        description: widget.readOnly
            ? context.tr('This profile is built in and cannot be changed here.')
            : context.tr('Rules run top to bottom; the first match wins.'),
        illustration: NullStatusIllustration.rules,
        action: _editable
            ? TonalButton(
                size: TonalButtonSize.bar,
                glyph: AppGlyphs.add,
                label: context.tr('Add rule'),
                onPressed: _add,
              )
            : null,
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
      itemCount: _rules.length,
      onReorderItem: _editable ? _reorder : (_, _) {},
      itemBuilder: (context, index) {
        final rule = _rules[index];
        // DecorationListItem rounds from the row's position in the group; a
        // reorderable list is not built through generateGroup, so the position
        // has to be supplied here or the rows come out square.
        final position = ItemPosition.get(index, _rules.length);
        final row = ItemPositionProvider(
          position: position,
          child: DecorationListItem(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(ruleName(rule, index)),
            subtitle: ruleRowSubtitle(context, rule),
            leading: const GlyphIcon(AppGlyphs.rules),
            trailing: _editable ? SortHandle(index: index) : null,
            onPressed: _editable ? () => _edit(index) : null,
          ),
        );
        if (!_editable) return KeyedSubtree(key: ObjectKey(rule), child: row);
        return ReorderableDelayedDragStartListener(
          key: ObjectKey(rule),
          index: index,
          child: ContextMenuRegion(
            menuItems: [
              PopupMenuItem(
                glyph: AppGlyphs.edit,
                label: context.tr('Edit'),
                onPressed: () => _edit(index),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.toggle,
                label: context.tr('Disabled'),
                checked: rule['disabled'] == true,
                onPressed: () => _toggleDisabled(index),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.delete,
                label: context.tr('Delete'),
                danger: true,
                onPressed: () => _delete(index),
              ),
            ],
            child: row,
          ),
        );
      },
    );
  }
}
