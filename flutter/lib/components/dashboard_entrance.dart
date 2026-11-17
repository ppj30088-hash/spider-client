import '../widgets.dart';

/// The dashboard's first-frame entrance: the cards fade in and rise a
/// few pixels once, when the app opens. It runs only on the first build
/// of the session — the page stays alive across tabs, so the state is
/// not rebuilt on return — and it never delays anything: the content is
/// already there underneath, and 350 ms later the animation is done.
/// The [opacity] getter is what the entrance test reads.
class DashboardEntrance extends StatefulWidget {
  const DashboardEntrance({super.key, required this.child});
  final Widget child;
  @override
  State<DashboardEntrance> createState() => _DashboardEntranceState();
}

class _DashboardEntranceState extends State<DashboardEntrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// The current fade, 0 on the first frame and 1 once the entrance is done.
  double get opacity => _animation.value;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Opacity(
        opacity: _animation.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - _animation.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
