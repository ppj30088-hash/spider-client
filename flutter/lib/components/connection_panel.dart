import 'dart:async';

import '../common/routed_ip_probe.dart';
import '../widgets.dart';
import 'connected_buttons.dart';
import 'dashboard_chip.dart';
import 'helper_country.dart';

/// The one "Connection" card on the dashboard: Aether, Psiphon and the
/// chain in a single section, one tap connects with no config.
///
/// A mode selector picks the tunnel — Aether alone (finds a route by
/// itself), Psiphon alone (finds a working Psiphon server by itself), or
/// Chained (warp -> psiphon -> internet) — and the selector is the single
/// source of truth for the mode. The old separate cards each owned half
/// of this state, which is how switching from chain to Psiphon left the
/// chain toggle on while the chain was no longer running: the toggle was
/// a stored preference, updated only when the Aether profile was
/// selected. Here the shown mode comes from the runner itself
/// (the status map's `mode` while a helper runs, the selected profile
/// otherwise), so the card can never disagree with what is running.
///
/// Switching mode while the service runs stops the old helper first
/// (an explicit `aether.stop` before the new profile is selected), so
/// the previous tunnel never keeps running behind the new one; switching
/// while off just remembers the choice for the next connect.
///
/// The exit country picker belongs to Psiphon, so it only appears when
/// the mode involves Psiphon (Psiphon or Chained). Aether alone has no
/// picker — it picks the nearest route itself.
///
/// "Start with" is chosen before connecting: "New IP" starts with a
/// fresh scan, "Previous IP" reconnects to the last route that worked.
/// The choice is stored and honoured when Connect is tapped; while
/// connected (or after a failure) tapping it restarts with that choice
/// right away, which is what the old Previous/New IP buttons did.
///
/// The card only says "Connected" when traffic really flows: the helper
/// process being alive and its SOCKS port answering is not enough — a
/// gateway can answer the handshake and still drop every byte. So the
/// card runs the same egress check the Status card uses and trusts the
/// route only once an exit IP comes back through it. Until then it keeps
/// showing the helper's log lines.
///
/// When a start fails, the card keeps the failure and its log lines
/// visible instead of flipping to Off: the helper is dead, so those
/// lines are the only thing that says why it died.
class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({super.key});
  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

/// The three tunnels the card can run, in selector order.
const _modes = ['aether', 'psiphon', 'chain'];

String _modeLabel(String mode) => switch (mode) {
      'psiphon' => 'Psiphon',
      'chain' => 'Chained',
      _ => 'Aether',
    };

Glyph _modeGlyph(String mode) => switch (mode) {
      'psiphon' => AppGlyphs.link,
      'chain' => AppGlyphs.split,
      _ => AppGlyphs.target,
    };

class _ConnectionPanelState extends State<ConnectionPanel> {
  Json? _status;
  String? _error;
  bool _busy = false;
  bool _probing = false;
  bool? _routeOk;
  DateTime? _lastProbeAt;
  Timer? _timer;
  BoxController? _box;
  RoutedIpProbe? _probe;
  String _mode = 'aether';
  String _startWith = 'new';
  String _psiphonRegion = '';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  // context.box is an inherited widget: it cannot be read in initState.
  // The first didChangeDependencies runs right after, with the scope mounted.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box == null) {
      _box = context.box;
      final prefs = context.box.preferences;
      // The old chain switch stored one boolean; the mode selector stores
      // the mode itself. A stored chain switch migrates to the chain mode.
      final stored = prefs['helperMode'] as String?;
      _mode = _modes.contains(stored)
          ? stored!
          : prefs['aetherChain'] == true
              ? 'chain'
              : 'aether';
      final startWith = prefs['helperStartWith'] as String?;
      _startWith = startWith == 'previous' ? 'previous' : 'new';
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _probe?.cancel();
    super.dispose();
  }

  /// The mode the card shows: the runner's own mode while a helper runs
  /// (the status map reports it), the selected helper profile while one
  /// is selected but the helper is down, and the stored choice otherwise.
  String get _effectiveMode {
    final running = _status?['mode'] as String?;
    if (running != null && _modes.contains(running)) return running;
    if (_status?['chainSelected'] == true) return 'chain';
    if (_status?['psiphonSelected'] == true) return 'psiphon';
    if (_status?['aetherSelected'] == true) return 'aether';
    return _mode;
  }

  Future<void> _refresh() async {
    final box = _box;
    if (!mounted || box == null || box.remote) return;
    try {
      // Both status calls return the same helper map; one poll is enough.
      final status = json(await box.aetherStatus());
      if (!mounted) return;
      final helperReady = status['connected'] == true;
      final selected = status['aetherSelected'] == true ||
          status['chainSelected'] == true ||
          status['psiphonSelected'] == true;
      setState(() {
        _status = status;
        _error = null;
        _psiphonRegion = (status['psiphonRegion'] as String?) ?? '';
        if (!helperReady || !selected) _routeOk = null;
      });
      _maybeProbe(helperReady: helperReady, selected: selected);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = BoxController.describe(error));
    }
  }

  /// Validates the route with a real egress check, throttled: every 10s
  /// while the route is unproven, every 30s once it works (to catch a route
  /// that dies mid-session). Runs only while the service is up on a helper
  /// profile and the helper answers its port.
  void _maybeProbe({required bool helperReady, required bool selected}) {
    final box = _box;
    if (!mounted || box == null || !box.running || !helperReady || !selected || _probing) return;
    final interval = _routeOk == true
        ? const Duration(seconds: 30)
        : const Duration(seconds: 10);
    final last = _lastProbeAt;
    if (last != null && DateTime.now().difference(last) < interval) return;
    unawaited(_probeRoute());
  }

  Future<void> _probeRoute() async {
    final box = _box;
    if (box == null || _probing) return;
    _probing = true;
    _lastProbeAt = DateTime.now();
    _probe?.cancel();
    final probe = RoutedIpProbe(box);
    _probe = probe;
    try {
      final result = await probe
          .egress(force: true)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final ip = result['ip'] as String?;
      setState(() => _routeOk = ip != null && ip.isNotEmpty);
    } catch (_) {
      if (!mounted) return;
      setState(() => _routeOk = false);
    } finally {
      _probing = false;
    }
  }

  Future<dynamic> _ensureFor(String mode) {
    final box = context.box;
    return switch (mode) {
      'psiphon' => box.psiphonEnsure(),
      'chain' => box.psiphonEnsureChain(),
      _ => box.aetherEnsure(),
    };
  }

  Future<void> _connect() async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _routeOk = null;
      _lastProbeAt = null;
    });
    try {
      // The choice made before connecting: a fresh scan, or the last
      // route that worked. The next core start consumes it once.
      box.helperFreshStart = _startWith == 'new';
      final ensured = json(await _ensureFor(_effectiveMode));
      final id = ensured['profileId'];
      if (id == null) throw Exception('Helper profile was not created');
      await box.profileSelect(id);
      // Selecting while running already switches the service; a stopped
      // service still needs its start.
      if (!box.running) await box.serviceStart();
      await _refresh();
    } catch (error) {
      box.helperFreshStart = false;
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _routeOk = null;
      _lastProbeAt = null;
    });
    try {
      await box.serviceStop();
      await _refresh();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks another tunnel. While the service runs on a helper, the old
  /// helper is stopped first and the new profile is selected, so the
  /// reload restarts the core and the helper in the new mode; the old
  /// process never keeps running behind the new one. While off, the
  /// choice is only remembered for the next connect.
  Future<void> _onModeSelected(String mode) async {
    if (_busy || mode == _effectiveMode) return;
    final box = context.box;
    final helperRunning = _status?['running'] == true;
    setState(() {
      _busy = true;
      _mode = mode;
    });
    try {
      box.helperFreshStart = _startWith == 'new';
      await box.setPreferences({'helperMode': mode});
      if (helperRunning) {
        await box.aetherStop();
        final ensured = json(await _ensureFor(mode));
        final id = ensured['profileId'];
        if (id == null) throw Exception('Helper profile was not created');
        await box.profileSelect(id);
      }
      await _refresh();
    } catch (error) {
      box.helperFreshStart = false;
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks what a connect starts with, before connecting. The choice is
  /// stored and honoured on the next connect; while connected (or after a
  /// failure) it restarts right away with that choice, which is what the
  /// old Previous/New IP buttons did.
  Future<void> _onStartWithSelected(String choice) async {
    if (_busy) return;
    final box = context.box;
    final connected = _isConnected;
    final failed = _isFailed;
    setState(() => _startWith = choice);
    try {
      await box.setPreferences({'helperStartWith': choice});
      if (connected || failed) {
        setState(() {
          _routeOk = null;
          _lastProbeAt = null;
        });
        if (choice == 'new') {
          await box.aetherRescan();
        } else {
          await box.aetherReconnect();
        }
        await _refresh();
      }
    } catch (error) {
      box.report(error);
    }
  }

  /// Applies a new exit country (Psiphon's egress region). While running
  /// in a Psiphon mode the helper restarts with a fresh scan under the new
  /// country; while off the choice is stored and used on the next connect.
  /// It only rescans when actually running in a Psiphon mode — changing
  /// the country while on plain Aether must not restart Aether, which
  /// ignores it.
  Future<void> _onCountrySelected(String code) async {
    if (_busy || code == _psiphonRegion) return;
    final box = context.box;
    final mode = _effectiveMode;
    setState(() {
      _busy = true;
      _psiphonRegion = code;
    });
    try {
      await box.helperSetCountries(psiphonRegion: code);
      if (box.running && (mode == 'psiphon' || mode == 'chain')) {
        setState(() {
          _routeOk = null;
          _lastProbeAt = null;
        });
        await box.aetherRescan();
      }
      await _refresh();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _isConnected {
    final status = _status;
    final helperReady = status?['connected'] == true;
    final selected = status?['aetherSelected'] == true ||
        status?['chainSelected'] == true ||
        status?['psiphonSelected'] == true;
    return helperReady && selected && _routeOk == true;
  }

  bool get _isFailed {
    final status = _status;
    final helperReady = status?['connected'] == true;
    final selected = status?['aetherSelected'] == true ||
        status?['chainSelected'] == true ||
        status?['psiphonSelected'] == true;
    final uptimeMs = status?['uptimeMs'] as int?;
    final startupMs = status?['startupMs'] as int? ?? 90000;
    final pastStartup = uptimeMs != null && uptimeMs >= startupMs;
    return helperReady && selected && _routeOk == false && pastStartup;
  }

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    final status = _status;
    // Helper up means only this: its process is alive and something answers
    // on its SOCKS port. It says nothing about the route behind it.
    final helperReady = status?['connected'] == true;
    final selected = status?['aetherSelected'] == true ||
        status?['chainSelected'] == true ||
        status?['psiphonSelected'] == true;
    // The helper's startup window comes from the native side: 90s for the
    // warp scan, longer for Psiphon and the chain. Before that it is still
    // setting up (loading its identity, then scanning), so a failed egress
    // probe only means "no route yet", not "no route at all". Declaring
    // failure earlier is how the card said "No working route" while
    // registration was still retrying. Only after the window may a failed
    // probe mean failure; the probe keeps running, so a route that comes
    // up late still flips the card to Connected.
    final uptimeMs = status?['uptimeMs'] as int?;
    final startupMs = status?['startupMs'] as int? ?? 90000;
    final pastStartup = uptimeMs != null && uptimeMs >= startupMs;
    final connected = helperReady && selected && _routeOk == true;
    final finding = helperReady && selected && (_routeOk == null || !pastStartup);
    final failed = helperReady && selected && _routeOk == false && pastStartup;
    final log = (status?['log'] as List?)?.whereType<String>().toList() ?? [];
    // A failed start leaves the helper dead, so the card would otherwise
    // say Off and hide the log lines that say why it died. The native side
    // keeps the last start failure (message plus log tail) in the status
    // until the next start or stop; show it while a helper profile is
    // selected and the helper is down.
    final lastError = (status?['lastError'] as String?)?.trim() ?? '';
    final startFailed = lastError.isNotEmpty && !helperReady && selected;
    final stateText = _error != null
        ? _error!
        : startFailed
            ? context.tr("Couldn't start")
            : connected
                ? context.tr('Connected')
                : failed
                    ? context.tr('No working route')
                    : finding
                        ? context.tr('Finding a route…')
                        : context.tr('Off');
    final tone = connected
        ? DashboardChipTone.ok
        : finding || failed || startFailed
            ? DashboardChipTone.warn
            : DashboardChipTone.idle;
    final mode = _effectiveMode;
    final modeInvolvesPsiphon = mode == 'psiphon' || mode == 'chain';
    return BoxPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTitle(
            'Connection',
            AppGlyphs.target,
            trailing: _busy || finding
                ? const ActivityIndicator(size: 16)
                : DashboardChip(label: stateText, tone: tone),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('Aether, Psiphon, or both chained — no config needed.'),
            style: context.listCaptionStyle,
          ),
          const SizedBox(height: 16),
          Text(
            context.tr('Mode').toUpperCase(),
            style: AppTextStyle.caption1.of(context).copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: 8),
          DashboardConnectedGroup(
            children: [
              for (final (index, entry) in _modes.indexed)
                Expanded(
                  child: DashboardConnectedButton(
                    selected: mode == entry,
                    first: index == 0,
                    last: index == _modes.length - 1,
                    outer: 26,
                    inner: 12,
                    background:
                        SurfaceLevel.block.colorOf(context.colorScheme),
                    semanticLabel: _modeLabel(entry),
                    onTap: _busy || finding
                        ? () {}
                        : () => _onModeSelected(entry),
                    builder: (foreground) => SizedBox(
                      height: 52,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 6,
                        children: [
                          GlyphIcon(_modeGlyph(entry),
                              size: 18, color: foreground),
                          Flexible(
                            child: Text(
                              _modeLabel(entry),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.footnote
                                  .of(context, emphasized: true)
                                  .copyWith(color: foreground),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // The country picker belongs to Psiphon, not to Aether alone:
          // Aether picks the nearest route itself, while Psiphon and the
          // chain exit through Psiphon in the country chosen here.
          if (modeInvolvesPsiphon) ...[
            const SizedBox(height: 16),
            HelperCountryPicker(
              value: _psiphonRegion,
              enabled: !_busy,
              onSelected: _onCountrySelected,
            ),
          ],
          const SizedBox(height: 16),
          Text(
            context.tr('Start with').toUpperCase(),
            style: AppTextStyle.caption1.of(context).copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: 8),
          DashboardConnectedGroup(
            children: [
              for (final (index, choice) in ['new', 'previous'].indexed)
                Expanded(
                  child: DashboardConnectedButton(
                    selected: _startWith == choice,
                    first: index == 0,
                    last: index == 1,
                    outer: 26,
                    inner: 12,
                    background:
                        SurfaceLevel.block.colorOf(context.colorScheme),
                    semanticLabel: context.tr(
                        choice == 'new' ? 'New IP' : 'Previous IP'),
                    onTap: () => _onStartWithSelected(choice),
                    builder: (foreground) => SizedBox(
                      height: 52,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 6,
                        children: [
                          GlyphIcon(
                            choice == 'new'
                                ? AppGlyphs.sparkle
                                : AppGlyphs.clock,
                            size: 18,
                            color: foreground,
                          ),
                          Flexible(
                            child: Text(
                              context.tr(choice == 'new'
                                  ? 'New IP'
                                  : 'Previous IP'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.footnote
                                  .of(context, emphasized: true)
                                  .copyWith(color: foreground),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if ((finding || failed) && log.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              log.last,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1.of(context).copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          // The full start error, log tail included, kept visible and
          // selectable so a screenshot or a copy carries the fatal lines.
          if (startFailed) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: SingleChildScrollView(
                child: SelectableText(
                  lastError,
                  style: AppTextStyle.caption1.of(context).copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (connected || failed)
            FilledButton(
              onPressed: _busy ? null : _disconnect,
              child: Text(context.tr('Disconnect')),
            )
          else
            FilledButton(
              onPressed: _busy || finding ? null : _connect,
              child: Text(
                context.tr(
                  box.running
                      ? switch (mode) {
                          'psiphon' => 'Switch to Psiphon',
                          'chain' => 'Switch to chain',
                          _ => 'Switch to Aether',
                        }
                      : switch (mode) {
                          'psiphon' => 'Connect with Psiphon',
                          'chain' => 'Connect chained',
                          _ => 'Connect',
                        },
                ),
              ),
            ),
          if (!connected && !failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr(
                  switch (mode) {
                    'psiphon' => 'Psiphon only',
                    'chain' => 'Chained: Aether + Psiphon',
                    _ => 'Aether only',
                  },
                ),
                style: context.listCaptionStyle,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
