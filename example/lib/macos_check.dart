// A manual check page for the macOS host (roadmap M3): the Accessibility
// permission flow and the App Sandbox test (docs/design.md §7.3). Run it
// with:
//
//   flutter run -d macos -t lib/macos_check.dart
//
// Nothing is injected until you press a button; each button counts down five
// seconds, then injects real input into whatever is under the pointer or in
// front, through an in-memory link in this one process. The log shows states
// and counts only, never what was typed or where (docs/design.md §6.6).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

const _window = MethodChannel('remote_input_example/window');
const _enter = 0x00070028;

void main() => runApp(const MacosCheckApp());

/// The check page's app.
class MacosCheckApp extends StatelessWidget {
  /// Creates the app.
  const MacosCheckApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'remote_input macOS check',
    home: MacosCheckPage(),
  );
}

/// Buttons for each manual check, and a log.
class MacosCheckPage extends StatefulWidget {
  /// Creates the page.
  const MacosCheckPage({super.key});

  @override
  State<MacosCheckPage> createState() => _MacosCheckPageState();
}

class _MacosCheckPageState extends State<MacosCheckPage> {
  RemoteInputPermissionStatus? _status;
  StreamSubscription<RemoteInputPermissionStatus>? _statusSub;
  List<DisplayInfo> _displays = const [];
  final List<String> _log = [];
  final TextEditingController _field = TextEditingController();
  final Stopwatch _clock = Stopwatch()..start();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _statusSub = RemoteInputPermissions.statusChanges.listen((s) {
      setState(() => _status = s);
      _say('permission: ${s.name}');
    });
    _loadDisplays();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _loadDisplays() async {
    if (!RemoteInputHost.isSupported) return;
    final displays = await RemoteInputHost().displays();
    setState(() => _displays = displays);
  }

  void _say(String line) {
    final t = (_clock.elapsedMilliseconds / 1000).toStringAsFixed(3);
    setState(() => _log.insert(0, '$t  $line'));
  }

  /// Counts down, starts a session on [surface] over an in-memory link, runs
  /// [script] as the viewer, and logs the states and counts.
  Future<void> _run(
    String name,
    Future<SharedSurface?> Function() surfaceOf,
    Future<void> Function(RemoteInputViewer viewer) script,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      for (var i = 5; i > 0; i--) {
        _say('$name in $i s');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final surface = await surfaceOf();
      if (surface == null) {
        _say('$name: no surface');
        return;
      }
      final pair = MemoryInputLink.pair();
      final ControlSession session;
      try {
        session = RemoteInputHost().enable(link: pair.host, surface: surface);
      } on HostUnavailableException catch (e) {
        _say('$name: host unavailable (${e.reason.name})');
        return;
      }
      final sub = session.stateChanges.listen((s) => _say('state: $s'));
      final viewer = RemoteInputViewer(link: pair.viewer);
      try {
        await viewer.stateChanges
            .firstWhere((s) => s.isActive)
            .timeout(const Duration(seconds: 5));
        await script(viewer);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } on TimeoutException {
        _say('$name: the session never became active');
      } finally {
        final stats = session.stats;
        _say(
          '$name: injected ${stats.injected}, dropped '
          '${{for (final e in stats.dropped.entries) e.key.name: e.value}}',
        );
        session.stop();
        await viewer.close();
        await sub.cancel();
        pair.host.close();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<SharedSurface?> _primary() async {
    final displays = await RemoteInputHost().displays();
    final primary = displays.where((d) => d.isPrimary);
    return primary.isEmpty ? null : SharedSurface.display(primary.first.id);
  }

  Future<SharedSurface?> _ownWindow() async {
    final info = await _window.invokeMapMethod<String, Object?>('describe');
    if (info == null) return null;
    return SharedSurface.window(
      info['windowNumber']! as int,
      contentInsets: EdgeInsets.only(
        top: (info['insetTop']! as num).toDouble(),
      ),
    );
  }

  Future<void> _typeLine(RemoteInputViewer v) async {
    v.text('remote_input check: héllo wörld 👋 0123456789');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    v
      ..key(_enter, KeyAction.down)
      ..key(_enter, KeyAction.up);
  }

  Future<void> _clickDisplays() async {
    final displays = await RemoteInputHost().displays();
    for (final d in displays) {
      await _run(
        'click display ${displays.indexOf(d) + 1}',
        () async => SharedSurface.display(d.id),
        (v) async {
          v.pointerMove(const Offset(0.5, 0.5));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          v.click(const Offset(0.5, 0.5));
        },
      );
    }
  }

  Future<void> _circle(RemoteInputViewer v) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    var a = 0.0;
    while (DateTime.now().isBefore(end)) {
      a += 0.08;
      v.pointerMove(Offset(0.5 + 0.15 * math.cos(a), 0.5 + 0.15 * math.sin(a)));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = RemoteInputHost.isSupported;
    final ready = supported && _status == RemoteInputPermissionStatus.granted;
    return Scaffold(
      appBar: AppBar(title: const Text('remote_input: macOS check')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Host supported: $supported · Accessibility: '
            '${_status?.name ?? '…'} · displays: ${_displays.length}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () async => _say(
                  'request: ${(await RemoteInputPermissions.request()).name}',
                ),
                child: const Text('Request permission'),
              ),
              OutlinedButton(
                onPressed: () async => _say(
                  'open settings: ${await RemoteInputPermissions.openSettings()}',
                ),
                child: const Text('Open Accessibility settings'),
              ),
            ],
          ),
          const Divider(height: 32),
          const Text(
            'Each button waits 5 s, then injects. Bring the target app to '
            'the front first, and keep your hands off unless the check '
            'says otherwise.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: ready && !_busy
                    ? () => _run('type into the front app', _primary, _typeLine)
                    : null,
                child: const Text('Type a line into the front app'),
              ),
              ElevatedButton(
                onPressed: ready && !_busy ? _clickDisplays : null,
                child: const Text('Click the centre of each display'),
              ),
              ElevatedButton(
                onPressed: ready && !_busy
                    ? () => _run('circle', _primary, _circle)
                    : null,
                child: const Text('Circle for 8 s (touch the mouse to pause)'),
              ),
              ElevatedButton(
                onPressed: ready && !_busy
                    ? () => _run('type into this window', _ownWindow, _typeLine)
                    : null,
                child: const Text('Type into this window'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _field,
            decoration: const InputDecoration(
              labelText: 'This window\'s field (click it before typing here)',
            ),
          ),
          const SizedBox(height: 8),
          const TextField(
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'A password field (Secure Event Input blocks keys)',
            ),
          ),
          const Divider(height: 32),
          for (final line in _log)
            Text(line, style: const TextStyle(fontFamily: 'Menlo')),
        ],
      ),
    );
  }
}
