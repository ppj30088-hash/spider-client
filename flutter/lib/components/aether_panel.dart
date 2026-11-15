import 'dart:async';

import '../common/routed_ip_probe.dart';
import '../widgets.dart';
import 'dashboard_chip.dart';

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
/// visible "Try another route" that rescans from scratch.
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
      final selected = status['selected'] == true;
      setState(() {
        _status = status;
        _error = null;
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
  /// Aether profile and the helper answers its port.
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
      final ensured = json(await box.aetherEnsure());
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

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    final status = _status;
    // Helper up means only this: its process is alive and something answers
    // on its SOCKS port. It says nothing about the route behind it.
    final helperReady = status?['connected'] == true;
    final selected = status?['selected'] == true;
    final connected = helperReady && selected && _routeOk == true;
    final finding = helperReady && selected && _routeOk == null;
    final failed = helperReady && selected && _routeOk == false;
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
          Row(
            children: [
              if (failed) ...[
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _rescan,
                    child: Text(context.tr('Try another route')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _disconnect,
                    child: Text(context.tr('Disconnect')),
                  ),
                ),
              ] else
                Expanded(
                  child: FilledButton(
                    onPressed: _busy || finding
                        ? null
                        : connected && selected
                            ? _disconnect
                            : _connect,
                    child: Text(
                      context.tr(
                        connected && selected
                            ? 'Disconnect'
                            : box.running
                                ? 'Switch to Aether'
                                : 'Connect with Aether',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
