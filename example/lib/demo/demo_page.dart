import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import '../viewer/capture_view.dart';
import '../widgets/send_keys_menu.dart';
import '../widgets/session_state_view.dart';
import 'virtual_desktop.dart';

/// Host and viewer in one app, over an in-memory link, with a drawn
/// presenter's desktop: the package's whole path, from a click in the
/// viewer's view to the injector, without two machines or injecting
/// anything for real.
///
/// The host is a real [RemoteInputHost] on a [FakeHostPlatform]: its
/// [RecordingInjector] feeds a [VirtualDesktop] instead of the OS.
class DemoPage extends StatefulWidget {
  /// Creates the demo.
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

/// One run of the demo: a link, a host session and a viewer.
class _Demo {
  _Demo({
    required this.platform,
    required this.desktop,
    required this.link,
    required this.session,
    required this.viewer,
  });

  final FakeHostPlatform platform;
  final VirtualDesktop desktop;
  final ({MemoryInputLink host, MemoryInputLink viewer}) link;
  final ControlSession session;
  final RemoteInputViewer viewer;
  final List<StreamSubscription<Object?>> subscriptions = [];

  void dispose() {
    for (final s in subscriptions) {
      s.cancel();
    }
    session.stop();
    viewer.close();
    link.host.close();
    desktop.dispose();
  }
}

class _DemoPageState extends State<DemoPage> {
  PeerPlatform _presenter = PeerPlatform.windows;
  double _loss = 0;
  double _latencyMs = 0;
  KeyboardMode _keyboardMode = KeyboardMode.auto;
  bool _passwordField = false;

  _Demo? _demo;
  String? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _start();
    // Stats are counters; refresh them a few times a second.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _demo?.dispose();
    super.dispose();
  }

  void _start() {
    _demo?.dispose();
    _demo = null;
    _error = null;
    _passwordField = false;

    final mac = _presenter == PeerPlatform.macos;
    final display = DisplayInfo(
      id: 1,
      bounds: mac
          ? const Rect.fromLTWH(0, 0, 1440, 900) // Points, on a Retina display.
          : const Rect.fromLTWH(0, 0, 1920, 1080), // Pixels.
      scaleFactor: mac ? 2 : 1,
      isPrimary: true,
    );
    final desktop = VirtualDesktop(
      bounds: display.bounds,
      presenter: _presenter,
    );
    final injector = RecordingInjector();
    injector.onInject = (event) {
      injector.clear(); // The desktop keeps what it draws; nothing else.
      return desktop.apply(event);
    };
    final platform = FakeHostPlatform(
      platform: _presenter,
      injector: injector,
      surfaces: FakeSurfaceResolver(displays: [display]),
    );
    final link = MemoryInputLink.pair(
      loss: _loss,
      reorder: _loss > 0,
      delay: Duration(milliseconds: _latencyMs.round()),
    );
    final ControlSession session;
    try {
      session = RemoteInputHost(platform: platform).enable(
        link: link.host,
        surface: SharedSurface.display(display.id),
        options: HostOptions(
          expiresAt: DateTime.now().add(const Duration(minutes: 30)),
        ),
      );
    } on StateError {
      link.host.close();
      desktop.dispose();
      _error =
          'Another control session is live in this app (on the host '
          'screen). Stop it there first: one session at a time.';
      return;
    }
    final viewer = RemoteInputViewer(link: link.viewer);
    final demo = _Demo(
      platform: platform,
      desktop: desktop,
      link: link,
      session: session,
      viewer: viewer,
    );
    demo.subscriptions
      ..add(session.stateChanges.listen((_) => _refresh()))
      ..add(viewer.stateChanges.listen((_) => _refresh()));
    _demo = demo;
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _restart() => setState(_start);

  void _simulateLocalInput() {
    final demo = _demo;
    if (demo == null) return;
    demo.platform.localActivity.simulateInput();
    demo.desktop.noteLocalInput();
  }

  void _setPasswordField(bool on) {
    final demo = _demo;
    if (demo == null) return;
    setState(() => _passwordField = on);
    demo.platform.secureContext.keyboard = on ? BlockReason.secureInput : null;
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _DemoSettings(
        presenter: _presenter,
        loss: _loss,
        latencyMs: _latencyMs,
        onApply: (presenter, loss, latency) {
          Navigator.pop(context);
          setState(() {
            _presenter = presenter;
            _loss = loss;
            _latencyMs = latency;
            _start();
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final demo = _demo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('One-machine demo'),
        actions: [
          IconButton(
            tooltip: 'Presenter and network settings',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: demo == null
            ? _ErrorView(message: _error ?? 'Not started', onRetry: _restart)
            : _body(context, demo),
      ),
    );
  }

  Widget _body(BuildContext context, _Demo demo) {
    final stopped = demo.session.state.isStopped;
    final hostPaused =
        demo.session.state == const SessionPaused(PauseReason.byHost);
    final touch =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (stopped)
          FilledButton.icon(
            key: const ValueKey('demo-restart'),
            onPressed: _restart,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start again'),
          )
        else
          FilledButton.icon(
            key: const ValueKey('demo-stop'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: demo.session.stop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        FilledButton.tonalIcon(
          key: const ValueKey('demo-pause'),
          onPressed: stopped
              ? null
              : hostPaused
              ? demo.session.resume
              : demo.session.pause,
          icon: Icon(hostPaused ? Icons.play_arrow : Icons.pause),
          label: Text(hostPaused ? 'Resume' : 'Pause'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('demo-local-input'),
          onPressed: stopped ? null : _simulateLocalInput,
          icon: const Icon(Icons.back_hand_outlined),
          label: const Text('Simulate local input'),
        ),
        FilterChip(
          label: const Text('Password field focused'),
          tooltip: 'Simulates Secure Event Input: keys are blocked',
          selected: _passwordField,
          onSelected: stopped ? null : _setPasswordField,
        ),
        _KeyboardModeMenu(
          mode: _keyboardMode,
          onChanged: (m) => setState(() => _keyboardMode = m),
        ),
        SendKeysMenu(viewer: demo.viewer, enabled: !stopped),
      ],
    );

    final viewerPanel = _Panel(
      icon: Icons.phone_android,
      title: 'Viewer',
      subtitle:
          'Control through this view: it stands in for the shared '
          "screen's video.",
      trailing: [
        SessionStateChip(state: demo.viewer.state, side: Side.viewer),
        Text(
          'RTT ${formatRtt(demo.viewer.stats.roundTripTime)}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: CaptureView(
              key: const ValueKey('demo-capture'),
              viewer: demo.viewer,
              contentSize: demo.desktop.size,
              keyboardMode: _keyboardMode,
              child: VirtualDesktopView(desktop: demo.desktop),
            ),
          ),
          if (touch) KeyBarView(viewer: demo.viewer),
        ],
      ),
    );
    final presenterPanel = _Panel(
      key: const ValueKey('presenter-panel'),
      icon: _presenter == PeerPlatform.macos
          ? Icons.laptop_mac
          : Icons.desktop_windows,
      title: "Presenter's desktop (${platformName(_presenter)})",
      subtitle: 'What the host injected, drawn instead of posted to the OS.',
      trailing: [SessionStateChip(state: demo.session.state, side: Side.host)],
      child: VirtualDesktopView(desktop: demo.desktop),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final panels = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: viewerPanel),
                  const SizedBox(width: 12),
                  Expanded(child: presenterPanel),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: viewerPanel),
                  const SizedBox(height: 8),
                  Expanded(child: presenterPanel),
                ],
              );
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              controls,
              const SizedBox(height: 12),
              Expanded(child: panels),
              const SizedBox(height: 8),
              _StatsRow(demo: demo, loss: _loss, latencyMs: _latencyMs),
            ],
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(icon, size: 20),
                Text(title, style: theme.textTheme.titleSmall),
                ...trailing,
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              subtitle,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.demo,
    required this.loss,
    required this.latencyMs,
  });

  final _Demo demo;
  final double loss;
  final double latencyMs;

  @override
  Widget build(BuildContext context) {
    final v = demo.viewer.stats;
    final s = demo.session.stats;
    final parts = [
      'Viewer sent ${v.sent}',
      'moves coalesced ${v.movesCoalesced}',
      'host received ${s.received}',
      'injected ${s.injected}',
      'dropped ${s.totalDropped}',
      'violations ${s.totalViolations}',
      'RTT ${formatRtt(v.roundTripTime)}',
      'link: ${(loss * 100).round()} % move loss, '
          '${latencyMs.round()} ms each way',
    ];
    return Text(
      parts.join('  ·  '),
      key: const ValueKey('demo-stats'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

class _KeyboardModeMenu extends StatelessWidget {
  const _KeyboardModeMenu({required this.mode, required this.onChanged});

  final KeyboardMode mode;
  final ValueChanged<KeyboardMode> onChanged;

  static String label(KeyboardMode m) => switch (m) {
    KeyboardMode.auto => 'Keys: auto',
    KeyboardMode.physical => 'Keys: physical',
    KeyboardMode.text => 'Keys: text',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<KeyboardMode>(
      tooltip: 'Keyboard mode',
      initialValue: mode,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final m in KeyboardMode.values)
          PopupMenuItem(value: m, child: Text(label(m))),
      ],
      child: Chip(
        avatar: const Icon(Icons.keyboard, size: 18),
        label: Text(label(mode)),
      ),
    );
  }
}

class _DemoSettings extends StatefulWidget {
  const _DemoSettings({
    required this.presenter,
    required this.loss,
    required this.latencyMs,
    required this.onApply,
  });

  final PeerPlatform presenter;
  final double loss;
  final double latencyMs;
  final void Function(PeerPlatform presenter, double loss, double latencyMs)
  onApply;

  @override
  State<_DemoSettings> createState() => _DemoSettingsState();
}

class _DemoSettingsState extends State<_DemoSettings> {
  late PeerPlatform _presenter = widget.presenter;
  late double _loss = widget.loss;
  late double _latency = widget.latencyMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Presenter', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<PeerPlatform>(
              segments: const [
                ButtonSegment(
                  value: PeerPlatform.windows,
                  label: Text('Windows'),
                  icon: Icon(Icons.desktop_windows),
                ),
                ButtonSegment(
                  value: PeerPlatform.macos,
                  label: Text('macOS'),
                  icon: Icon(Icons.laptop_mac),
                ),
              ],
              selected: {_presenter},
              onSelectionChanged: (s) => setState(() => _presenter = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              'Decides the shortcut mapping: Ctrl and ⌘ swap when exactly '
              'one end is a Mac.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Pointer-move loss: ${(_loss * 100).round()} %',
              style: theme.textTheme.titleMedium,
            ),
            Slider(
              value: _loss,
              max: 0.3,
              divisions: 30,
              onChanged: (v) => setState(() => _loss = v),
            ),
            Text(
              'Latency each way: ${_latency.round()} ms',
              style: theme.textTheme.titleMedium,
            ),
            Slider(
              value: _latency,
              max: 150,
              divisions: 30,
              onChanged: (v) => setState(() => _latency = v),
            ),
            Text(
              'Loss and reordering apply to the unreliable channel (moves); '
              'stale moves are dropped, never queued.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => widget.onApply(_presenter, _loss, _latency),
                child: const Text('Apply and restart'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
