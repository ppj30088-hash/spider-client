import 'dart:async';

import '../common/routed_ip_probe.dart';
import '../widgets.dart';
import 'dashboard_chip.dart';
import 'helper_country.dart';

/// The Aether card on the dashboard: one tap connects with no config.
///
/// Aether finds a reachable route by itself and opens a local SOCKS5 proxy;
/// the app routes the phone through it like any other SOCKS node. Tapping
/// Connect creates the Aether profile when it does not exist yet, selects it
/// and starts the service; tapping Disconnect stops the service, which also
/// stops the helper. While the helper scans, the card shows its last log line
/// so the wait is not a blank spinner.
///
/// The card only says "Connected" when traffic really flows: the helper
/// process being alive and its SOCKS port answering is not enough — a
/// gateway can answer the handshake and still drop every byte, which is
/// exactly how a dead route used to look "connected" while the speed stayed
/// at zero. So the card runs the same egress check the Status card uses and
/// trusts the route only once an exit IP comes back through it. Until then
/// it keeps showing the helper's log lines, and a failed route offers a
/// visible choice: "Previous IP" reconnects to the last gateway that worked,
/// "New IP" scans from scratch.
///
/// The "Chain with Psiphon" switch routes through Aether and then Psiphon
/// (warp -> psiphon -> internet): it connects with the chained profile
/// instead of the plain Aether one. While chained, an exit country picker
/// appears: the chain exits through Psiphon in the chosen country, and
/// changing it while connected rescans with the new country. Aether alone
/// has no country picker — it picks the nearest route itself.
class AetherPanel extends StatefulWidget {
  const AetherPanel({super.key});
  @override
  State<AetherPanel> createState() => _AetherPanelState();
}

class _AetherPanelState extends State<AetherPanel> {
  Json? _status;
  String? _error;
  bool _busy = false;
  bool _probing = false;
  bool? _routeOk;
  DateTime? _lastProbeAt;
  Timer? _timer;
  BoxController? _box;
  RoutedIpProbe? _probe;
  bool _chainEnabled = false;
  bool _chainSelected = false;
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
      _chainEnabled = context.box.preferences['aetherChain'] == true;
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _probe?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final box = _box;
    if (!mounted || box == null || box.remote) return;
    try {
      final status = json(await box.aetherStatus());
      if (!mounted) return;
      final helperReady = status['connected'] == true;
      // The chain is an Aether mode too: its profile counts as selected here.
      final selected = status['aetherSelected'] == true || status['chainSelected'] == true;
      final chainSelected = status['chainSelected'] == true;
      setState(() {
        _status = status;
        _error = null;
        _psiphonRegion = (status['psiphonRegion'] as String?) ?? '';
        _chainSelected = chainSelected;
        if (selected) _chainEnabled = chainSelected;
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
  /// that dies mid-session). Runs only while the service is up on the
  /// Aether or chain profile and the helper answers its port.
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

  Future<void> _connect() async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _routeOk = null;
      _lastProbeAt = null;
    });
    try {
      final ensured = json(
        await (_chainEnabled ? box.psiphonEnsureChain() : box.aetherEnsure()),
      );
      final id = ensured['profileId'];
      if (id == null) throw Exception('Aether profile was not created');
      await box.profileSelect(id);
      // Selecting while running already switches the service; a stopped
      // service still needs its start.
      if (!box.running) await box.serviceStart();
      await _refresh();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescan() async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _routeOk = null;
      _lastProbeAt = null;
    });
    try {
      await box.aetherRescan();
      await _refresh();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reconnects to the last gateway that worked instead of scanning a new one.
  Future<void> _reconnect() async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _routeOk = null;
      _lastProbeAt = null;
    });
    try {
      await box.aetherReconnect();
      await _refresh();
    } catch (error) {
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

  /// Applies a new chain exit country (Psiphon's egress region). While
  /// chained the helper restarts with a fresh scan under the new country;
  /// while off the choice is stored and used on the next connect. It only
  /// rescans when actually running chained — changing the country while
  /// on plain Aether must not restart Aether, which ignores it.
  Future<void> _onCountrySelected(String code) async {
    if (_busy || code == _psiphonRegion) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _psiphonRegion = code;
    });
    try {
      await box.helperSetCountries(psiphonRegion: code);
      if (box.running && _chainSelected) {
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

  /// Flips between the plain Aether profile and the chained one. While the
  /// service runs, switching the profile reloads the service and the helper
  /// restarts in the new mode; while off, the choice is remembered for the
  /// next connect.
  Future<void> _onChainChanged(bool enabled) async {
    if (_busy) return;
    final box = context.box;
    setState(() {
      _busy = true;
      _chainEnabled = enabled;
    });
    try {
      await box.setPreferences({'aetherChain': enabled});
      if (box.running) {
        final ensured = json(
          await (enabled ? box.psiphonEnsureChain() : box.aetherEnsure()),
        );
        final id = ensured['profileId'];
        if (id == null) throw Exception('Aether profile was not created');
        setState(() {
          _routeOk = null;
          _lastProbeAt = null;
        });
        await box.profileSelect(id);
        await _refresh();
      }
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    final status = _status;
    // Helper up means only this: its process is alive and something answers
    // on its SOCKS port. It says nothing about the route behind it.
    final helperReady = status?['connected'] == true;
    final selected = status?['aetherSelected'] == true || status?['chainSelected'] == true;
    final chainSelected = status?['chainSelected'] == true;
    // The helper's startup window comes from the native side: 90s for the
    // warp scan, longer for a chain (warp first, then Psiphon through it).
    // Before that it is still setting up (loading its identity, then
    // scanning), so a failed egress probe only means "no route yet", not
    // "no route at all". Declaring failure earlier is how the card said
    // "No working route" while registration was still retrying. Only after
    // the window may a failed probe mean failure; the probe keeps running,
    // so a route that comes up late still flips the card to Connected.
    final uptimeMs = status?['uptimeMs'] as int?;
    final startupMs = status?['startupMs'] as int? ?? 90000;
    final pastStartup = uptimeMs != null && uptimeMs >= startupMs;
    final connected = helperReady && selected && _routeOk == true;
    final finding = helperReady && selected && (_routeOk == null || !pastStartup);
    final failed = helperReady && selected && _routeOk == false && pastStartup;
    final log = (status?['log'] as List?)?.whereType<String>().toList() ?? [];
    final stateText = _error != null
        ? _error!
        : connected
            ? context.tr('Connected')
            : failed
                ? context.tr('No working route')
                : finding
                    ? context.tr('Finding a route…')
                    : context.tr('Off');
    final tone = connected
        ? DashboardChipTone.ok
        : finding || failed
            ? DashboardChipTone.warn
            : DashboardChipTone.idle;
    return BoxPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTitle(
            'Aether',
            AppGlyphs.target,
            trailing: _busy || finding
                ? const ActivityIndicator(size: 16)
                : DashboardChip(label: stateText, tone: tone),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('Finds a route by itself — no config needed.'),
            style: context.listCaptionStyle,
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('Chain with Psiphon'),
                      style: AppTextStyle.body.of(context),
                    ),
                    Text(
                      context.tr('Routes through Aether, then Psiphon.'),
                      style: context.listCaptionStyle,
                    ),
                  ],
                ),
              ),
              Switch(
                value: _chainEnabled,
                onChanged: _busy ? null : _onChainChanged,
              ),
            ],
          ),
          // The country picker belongs to the chain, not to Aether alone:
          // Aether picks the nearest route itself, while the chain exits
          // through Psiphon in the country chosen here.
          if (_chainEnabled) ...[
            const SizedBox(height: 8),
            HelperCountryPicker(
              value: _psiphonRegion,
              enabled: !_busy,
              onSelected: _onCountrySelected,
            ),
          ],
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
          const SizedBox(height: 12),
          if (failed) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _reconnect,
                    child: Text(context.tr('Previous IP')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _rescan,
                    child: Text(context.tr('New IP')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _disconnect,
              child: Text(context.tr('Disconnect')),
            ),
          ] else if (connected) ...[
            FilledButton(
              onPressed: _busy ? null : _disconnect,
              child: Text(context.tr('Disconnect')),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _reconnect,
                    child: Text(context.tr('Previous IP')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _rescan,
                    child: Text(context.tr('New IP')),
                  ),
                ),
              ],
            ),
          ] else
            FilledButton(
              onPressed: _busy || finding
                  ? null
                  : _connect,
              child: Text(
                context.tr(
                  box.running
                      ? (_chainEnabled ? 'Switch to chain' : 'Switch to Aether')
                      : _chainEnabled
                          ? 'Connect chained'
                          : 'Connect with Aether',
                ),
              ),
            ),
          if (chainSelected && !connected && !failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr('Chained: Aether + Psiphon'),
                style: context.listCaptionStyle,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
