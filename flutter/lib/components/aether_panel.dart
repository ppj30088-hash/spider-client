import 'dart:async';

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
class AetherPanel extends StatefulWidget {
  const AetherPanel({super.key});
  @override
  State<AetherPanel> createState() => _AetherPanelState();
}

class _AetherPanelState extends State<AetherPanel> {
  Json? _status;
  String? _error;
  bool _busy = false;
  Timer? _timer;
  BoxController? _box;

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
    super.dispose();
  }

  Future<void> _refresh() async {
    final box = _box;
    if (!mounted || box == null || box.remote) return;
    try {
      final status = json(await box.aetherStatus());
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = BoxController.describe(error));
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    final box = context.box;
    setState(() => _busy = true);
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

  Future<void> _disconnect() async {
    if (_busy) return;
    final box = context.box;
    setState(() => _busy = true);
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
    final connected = status?['connected'] == true;
    final running = status?['running'] == true;
    final selected = status?['selected'] == true;
    final starting = running && !connected;
    final log = (status?['log'] as List?)?.whereType<String>().toList() ?? [];
    final stateText = _error != null
        ? _error!
        : connected
            ? context.tr('Connected')
            : starting
                ? context.tr('Finding a route…')
                : context.tr('Off');
    final tone = connected
        ? DashboardChipTone.ok
        : starting
            ? DashboardChipTone.warn
            : DashboardChipTone.idle;
    return BoxPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTitle(
            'Aether',
            AppGlyphs.target,
            trailing: _busy || starting
                ? const ActivityIndicator(size: 16)
                : DashboardChip(label: stateText, tone: tone),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('Finds a route by itself — no config needed.'),
            style: context.listCaptionStyle,
          ),
          if (starting && log.isNotEmpty) ...[
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
              Expanded(
                child: FilledButton(
                  onPressed: _busy || starting
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
