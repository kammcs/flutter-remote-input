import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

import '../demo/demo_page.dart';
import '../links/host_server.dart';
import '../links/socket_link.dart';
import '../widgets/session_state_view.dart';
import 'permission_onboarding.dart';

/// How long control lasts before it stops by itself: a local backstop, as
/// a real app's grant would have (`HostOptions.expiresAt`).
const Duration controlExpiry = Duration(minutes: 30);

/// Lets one viewer control this computer, over the development WebSocket
/// link, after the person here allows it.
class HostPage extends StatefulWidget {
  /// Creates the host screen. [host] is for tests (a host on a
  /// `FakeHostPlatform`); by default this platform's host is used, if it
  /// has one.
  const HostPage({super.key, this.host});

  /// The host to use instead of this platform's.
  final RemoteInputHost? host;

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  RemoteInputHost? _host;
  HostUnavailableReason? _unavailable;

  List<DisplayInfo>? _displays;
  int? _displayId;

  HostServer? _server;
  List<String> _addresses = const [];
  String? _serverError;
  bool _starting = false;
  StreamSubscription<PairingRequest>? _requests;

  ControlSession? _session;
  SocketConnection? _connection;
  String? _viewerName;
  DateTime? _expiresAt;
  String? _lastEnded;
  StreamSubscription<SessionState>? _states;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final host =
        widget.host ?? (RemoteInputHost.isSupported ? RemoteInputHost() : null);
    _host = host;
    if (host != null) _checkAvailable();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _states?.cancel();
    _session?.stop();
    _connection?.close();
    _requests?.cancel();
    _server?.dispose();
    super.dispose();
  }

  void _checkAvailable() {
    setState(() => _unavailable = _host?.checkAvailable());
    if (_unavailable == null && _displays == null) _loadDisplays();
  }

  Future<void> _loadDisplays() async {
    final displays = await _host!.displays();
    if (!mounted) return;
    setState(() {
      _displays = displays;
      _displayId = displays
          .firstWhere((d) => d.isPrimary, orElse: () => displays.first)
          .id;
    });
  }

  Future<void> _startListening() async {
    setState(() {
      _starting = true;
      _serverError = null;
    });
    try {
      final server = await HostServer.start();
      final addresses = await server.addresses();
      if (!mounted) {
        server.dispose();
        return;
      }
      server.addListener(_rebuild);
      _requests = server.requests.listen(_onRequest);
      setState(() {
        _server = server;
        _addresses = addresses;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _serverError =
              "Couldn't listen on port $defaultHostPort: is another copy of "
              'this example running? (${e.runtimeType})',
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _stopListening() {
    _session?.stop();
    _requests?.cancel();
    _requests = null;
    _server?.dispose();
    setState(() => _server = null);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _onRequest(PairingRequest request) async {
    if (_session != null || _displayId == null) {
      request.deny();
      return;
    }
    final answer = await _askConsent(request);
    if (!mounted || answer == null || request.connection.isClosed) {
      if (!request.isAnswered) request.deny();
      return;
    }
    if (!answer.allow) {
      request.deny();
      return;
    }
    final connection = request.accept();
    final expiresAt = DateTime.now().add(controlExpiry);
    final ControlSession session;
    try {
      session = _host!.enable(
        link: connection.link,
        surface: SharedSurface.display(_displayId!),
        options: HostOptions(
          expiresAt: expiresAt,
          allowKeyboard: answer.allowKeyboard,
        ),
      );
    } on Object catch (e) {
      await connection.close();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is StateError
                  ? 'Another control session is live in this app.'
                  : "Couldn't start control (${e.runtimeType}).",
            ),
          ),
        );
      }
      return;
    }
    setState(() {
      _session = session;
      _connection = connection;
      _viewerName = request.name;
      _expiresAt = expiresAt;
      _lastEnded = null;
    });
    _states = session.stateChanges.listen((state) {
      if (state case SessionStopped()) _onStopped(state);
      _rebuild();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _rebuild());
  }

  void _onStopped(SessionStopped state) {
    _ticker?.cancel();
    _ticker = null;
    _states?.cancel();
    _states = null;
    _connection?.close();
    if (!mounted) return;
    setState(() {
      _lastEnded = describeState(state, Side.host);
      _session = null;
      _connection = null;
    });
  }

  Future<_Consent?> _askConsent(PairingRequest request) async {
    var dialogOpen = true;
    BuildContext? dialogContext;
    unawaited(
      request.cancelled.then((_) {
        // The viewer gave up: close the dialog.
        final c = dialogContext;
        if (dialogOpen && c != null && c.mounted) Navigator.pop(c);
      }),
    );
    final result = await showDialog<_Consent>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        dialogContext = context;
        return _ConsentDialog(request: request);
      },
    );
    dialogOpen = false;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host this computer')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: _host == null ? _unsupported(context) : _content(),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _unsupported(BuildContext context) {
    final theme = Theme.of(context);
    final canNeverHost = RemoteInputHost.limitations.contains(
      HostLimitation.unsupportedPlatform,
    );
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                canNeverHost
                    ? "This device can't be controlled"
                    : "This build can't control this computer yet",
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                canNeverHost
                    ? HostLimitation.unsupportedPlatform.description
                    : 'remote_input injects input on Windows and macOS, '
                          'through its native plugin, which this build '
                          "doesn't have loaded. The one-machine demo shows "
                          'the whole path with a drawn desktop.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => const DemoPage()),
                ),
                icon: const Icon(Icons.science_outlined),
                label: const Text('Open the one-machine demo'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      const _Limitations(),
    ];
  }

  List<Widget> _content() {
    final session = _session;
    return [
      if (session != null) ...[
        _ControlBanner(
          session: session,
          viewerName: _viewerName ?? 'A viewer',
          expiresAt: _expiresAt,
        ),
        const SizedBox(height: 12),
      ] else if (_lastEnded != null) ...[
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(_lastEnded!),
            subtitle: const Text('Control has ended.'),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_unavailable == HostUnavailableReason.permissionDenied) ...[
        PermissionOnboarding(onCheckAgain: _checkAvailable),
        const SizedBox(height: 12),
      ] else if (_unavailable != null) ...[
        Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text("This computer can't be controlled now"),
            subtitle: Text(switch (_unavailable!) {
              HostUnavailableReason.dpiUnaware =>
                'The app is not per-monitor DPI aware, so its coordinates '
                    'would be wrong. Check the Windows runner manifest.',
              HostUnavailableReason.permissionDenied => '',
              HostUnavailableReason.unsupportedPlatform =>
                'This platform has no injector.',
            }),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_unavailable == null) ...[
        _displayCard(),
        const SizedBox(height: 12),
        _listenCard(),
        const SizedBox(height: 12),
      ],
      const _Limitations(),
    ];
  }

  Widget _displayCard() {
    final displays = _displays;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Shared display',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'The viewer\'s pointer is confined to this display. Keys go '
              'to whichever window has focus, on any display. This app\'s '
              'own windows are off limits: the viewer can\'t click in them, '
              'and typing is blocked while this app is in front.',
            ),
            const SizedBox(height: 8),
            if (displays == null)
              const LinearProgressIndicator()
            else
              DropdownButton<int>(
                isExpanded: true,
                value: _displayId,
                onChanged: _session == null
                    ? (id) => setState(() => _displayId = id)
                    : null,
                items: [
                  for (final d in displays)
                    DropdownMenuItem(
                      value: d.id,
                      child: Text(
                        'Display ${d.id}: '
                        '${d.pixelSize.width.round()} × '
                        '${d.pixelSize.height.round()} px'
                        '${d.scaleFactor != 1 ? ' (@${d.scaleFactor}x)' : ''}'
                        '${d.isPrimary ? ', primary' : ''}',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _listenCard() {
    final theme = Theme.of(context);
    final server = _server;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Let a viewer connect', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const DevOnlyBanner(),
            const SizedBox(height: 12),
            if (!HostServer.isSupported)
              const Text('This platform cannot listen for connections.')
            else if (server == null) ...[
              if (_serverError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _serverError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              FilledButton.icon(
                onPressed: _starting ? null : _startListening,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Start listening'),
              ),
            ] else ...[
              const Text(
                'On the other device, choose "Control another '
                'computer" and enter:',
              ),
              const SizedBox(height: 8),
              Text('Address', style: theme.textTheme.labelLarge),
              if (_addresses.isEmpty)
                const Text('No network address found. Are you connected?')
              else
                for (final a in _addresses)
                  SelectableText(
                    '$a:${server.port}',
                    style: theme.textTheme.titleMedium,
                  ),
              const SizedBox(height: 8),
              Text('Code', style: theme.textTheme.labelLarge),
              Row(
                children: [
                  SelectableText(
                    '${server.code.substring(0, 3)} ${server.code.substring(3)}',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'New code',
                    onPressed: server.newCode,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              Text(
                'Each code works once. You will be asked before anyone gets '
                'control, and control ends after '
                '${controlExpiry.inMinutes} minutes.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _stopListening,
                child: const Text('Stop listening'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The person's answer in the consent dialog.
class _Consent {
  const _Consent({required this.allow, required this.allowKeyboard});

  final bool allow;
  final bool allowKeyboard;
}

class _ConsentDialog extends StatefulWidget {
  const _ConsentDialog({required this.request});

  final PairingRequest request;

  @override
  State<_ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<_ConsentDialog> {
  bool _allowKeyboard = true;

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return AlertDialog(
      icon: const Icon(Icons.screen_share_outlined),
      title: const Text('A viewer wants to control this computer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('"${r.name}" (the name they gave; not verified)'),
          if (r.remoteAddress != null) Text('From ${r.remoteAddress}'),
          const SizedBox(height: 12),
          Text(
            'They will be able to move your pointer on the shared display '
            'and type into whichever window has focus, until you stop them '
            'or ${controlExpiry.inMinutes} minutes pass. They can\'t click '
            'or type in this app, so its Stop button stays yours. Touch '
            'your mouse or keyboard at any time to pause them.',
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _allowKeyboard,
            onChanged: (v) => setState(() => _allowKeyboard = v ?? true),
            title: const Text('Allow the keyboard too'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            const _Consent(allow: false, allowKeyboard: false),
          ),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _Consent(allow: true, allowKeyboard: _allowKeyboard),
          ),
          child: const Text('Allow'),
        ),
      ],
    );
  }
}

/// The prominent "being controlled" banner, with Stop and Pause.
class _ControlBanner extends StatelessWidget {
  const _ControlBanner({
    required this.session,
    required this.viewerName,
    required this.expiresAt,
  });

  final ControlSession session;
  final String viewerName;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = session.state;
    final active = state.isActive;
    final background = active
        ? theme.colorScheme.error
        : theme.colorScheme.tertiaryContainer;
    final foreground = active
        ? theme.colorScheme.onError
        : theme.colorScheme.onTertiaryContainer;
    final hostPaused = state == const SessionPaused(PauseReason.byHost);
    final remaining = expiresAt?.difference(DateTime.now());
    final stats = session.stats;
    final viewerPlatform = session.viewerPlatform;
    return Card(
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: foreground),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mouse, color: foreground),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Being controlled by "$viewerName"',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(describeState(state, Side.host)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: foreground,
                      foregroundColor: background,
                    ),
                    onPressed: session.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: foreground,
                      side: BorderSide(color: foreground),
                    ),
                    onPressed: hostPaused ? session.resume : session.pause,
                    icon: Icon(hostPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(hostPaused ? 'Resume' : 'Pause'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                [
                  if (viewerPlatform != null)
                    'Viewer on ${platformName(viewerPlatform)}'
                        '${session.viewerIsWeb ? ' (browser)' : ''}',
                  if (remaining != null && !remaining.isNegative)
                    'ends in ${remaining.inMinutes}:'
                        '${(remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                  'received ${stats.received}',
                  'injected ${stats.injected}',
                  'dropped ${stats.totalDropped}',
                  'violations ${stats.totalViolations}',
                ].join('  ·  '),
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Limitations extends StatelessWidget {
  const _Limitations();

  @override
  Widget build(BuildContext context) {
    final limits = RemoteInputHost.limitations;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Can't be controlled on this device",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final l in limits)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(l.description)),
                  ],
                ),
              ),
            if (kIsWeb)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('A browser can be a viewer only.'),
              ),
          ],
        ),
      ),
    );
  }
}
