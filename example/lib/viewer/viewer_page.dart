import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remote_input/remote_input.dart';

import '../links/socket_link.dart';
import '../links/viewer_client.dart';
import '../widgets/send_keys_menu.dart';
import '../widgets/session_state_view.dart';
import 'capture_view.dart';
import 'remote_placeholder.dart';

/// Controls another computer that runs this example as a host, over the
/// development WebSocket link. Works on every platform.
///
/// On a short screen (under [compactHeight], or a phone with its soft
/// keyboard up) the app bar and the toolbar fold into one strip of buttons
/// beside the picture (above it, in portrait), the stats line goes, and the
/// key bar shows only while the picture keeps at least [minCaptureShare] of
/// the height.
class ViewerPage extends StatefulWidget {
  /// Creates the viewer screen. [viewer] is for tests: a viewer already
  /// connected (over a `MemoryInputLink`), shown at once and closed on
  /// disconnect.
  const ViewerPage({super.key, @visibleForTesting this.viewer});

  /// A viewer to show instead of the connect form.
  final RemoteInputViewer? viewer;

  /// Below this visible height, in logical pixels, the controls fold into
  /// a strip.
  static const double compactHeight = 480;

  /// The least share of the height the picture keeps.
  static const double minCaptureShare = 0.4;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _code = TextEditingController();
  late final TextEditingController _name = TextEditingController(
    text: 'Viewer on ${_deviceName()}',
  );
  final GlobalKey<FormState> _form = GlobalKey();

  bool _connecting = false;
  Completer<void>? _cancel;
  String? _error;

  SocketConnection? _connection;
  RemoteInputViewer? _viewer;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _ticker;
  RttWindow _rtt = RttWindow();
  GlobalKey _pictureKey = GlobalKey();

  KeyboardMode _keyboardMode = KeyboardMode.auto;
  TouchMode? _touchMode;
  bool _showKeyBar =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  static String _deviceName() {
    final os = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
    return kIsWeb ? 'a browser ($os)' : os;
  }

  @override
  void initState() {
    super.initState();
    final viewer = widget.viewer;
    if (viewer != null) _attach(viewer, null);
  }

  @override
  void dispose() {
    _cancel?.complete();
    _disconnect(rebuild: false);
    _address.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final uri = hostUri(_address.text)!;
    final cancel = Completer<void>();
    setState(() {
      _connecting = true;
      _cancel = cancel;
      _error = null;
    });
    try {
      final connection = await connectToHost(
        uri,
        code: _code.text,
        name: _name.text.trim(),
        cancel: cancel.future,
      );
      if (!mounted || cancel.isCompleted) {
        await connection.close();
        return;
      }
      setState(
        () => _attach(RemoteInputViewer(link: connection.link), connection),
      );
    } on PairingException catch (e) {
      if (mounted && !cancel.isCompleted) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _cancel = null;
        });
      }
    }
  }

  void _cancelConnect() {
    _cancel?.complete();
    setState(() {
      _connecting = false;
      _cancel = null;
    });
  }

  void _attach(RemoteInputViewer viewer, SocketConnection? connection) {
    _connection = connection;
    _viewer = viewer;
    _pictureKey = GlobalKey(); // A fresh capture for each viewer.
    _subscriptions
      ..add(viewer.stateChanges.listen((_) => _rebuild()))
      ..add(viewer.surfaceChanges.listen((_) => _rebuild()));
    _rtt = RttWindow();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _rtt.add(viewer.stats.roundTripTime);
      _rebuild();
    });
    _code.clear(); // Codes work once.
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _disconnect({bool rebuild = true}) {
    _ticker?.cancel();
    _ticker = null;
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _viewer?.close();
    _connection?.close();
    _viewer = null;
    _connection = null;
    if (rebuild) _rebuild();
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    final media = MediaQuery.of(context);
    // What the soft keyboard and the system bars leave.
    final visible =
        media.size.height - media.viewInsets.bottom - media.padding.vertical;
    final phoneWithKeyboardUp =
        media.size.shortestSide < 600 && media.viewInsets.bottom > 0;
    final compact =
        viewer != null &&
        (visible < ViewerPage.compactHeight || phoneWithKeyboardUp);
    return Scaffold(
      appBar: compact
          ? null
          : AppBar(
              title: const Text('Control another computer'),
              actions: viewer == null
                  ? null
                  : [
                      SendKeysMenu(
                        viewer: viewer,
                        enabled: viewer.state.isActive,
                      ),
                      IconButton(
                        tooltip: 'Disconnect',
                        icon: const Icon(Icons.link_off),
                        onPressed: _disconnect,
                      ),
                    ],
            ),
      body: SafeArea(
        child: viewer == null
            ? _connectForm(context)
            : compact
            ? _compact(viewer)
            : _controlled(viewer),
      ),
    );
  }

  Widget _connectForm(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DevOnlyBanner(),
                const SizedBox(height: 16),
                Text(
                  'On the other computer, open this example and choose '
                  '"Host this computer". Enter the address and code it shows.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _address,
                  enabled: !_connecting,
                  decoration: const InputDecoration(
                    labelText: "Host's address",
                    hintText: '192.168.1.20 or 192.168.1.20:$defaultHostPort',
                    prefixIcon: Icon(Icons.lan),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  validator: (v) =>
                      hostUri(v ?? '') == null ? 'Enter an address' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _code,
                  enabled: !_connecting,
                  decoration: const InputDecoration(
                    labelText: 'Code',
                    hintText: 'The six digits the host shows',
                    prefixIcon: Icon(Icons.pin),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  validator: (v) =>
                      (v ?? '').length == 6 ? null : 'Enter all six digits',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  enabled: !_connecting,
                  decoration: const InputDecoration(
                    labelText: 'Your name, shown to the host',
                    prefixIcon: Icon(Icons.badge_outlined),
                    border: OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(64)],
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (_connecting) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text(
                    'Waiting for the person at the host to allow control…',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _cancelConnect,
                    child: const Text('Cancel'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.cast_connected),
                    label: const Text('Connect'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TouchMode get _defaultTouchMode =>
      MediaQuery.sizeOf(context).shortestSide < 600
      ? TouchMode.trackpad
      : TouchMode.direct;

  /// The full layout: the toolbar above the picture, the stats below.
  Widget _controlled(RemoteInputViewer viewer) {
    final theme = Theme.of(context);
    final state = viewer.state;
    final stats = viewer.stats;
    final touchMode = _touchMode ?? _defaultTouchMode;
    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SessionStateChip(state: state, side: Side.viewer),
          Text(_rttText(), style: theme.textTheme.labelLarge),
          DropdownButton<KeyboardMode>(
            value: _keyboardMode,
            onChanged: (m) => setState(() => _keyboardMode = m!),
            items: [
              for (final (mode, label) in _keyboardModes)
                DropdownMenuItem(value: mode, child: Text('Keys: $label')),
            ],
          ),
          SegmentedButton<TouchMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: TouchMode.trackpad,
                label: Text('Trackpad'),
                icon: Icon(Icons.touch_app_outlined),
              ),
              ButtonSegment(
                value: TouchMode.direct,
                label: Text('Direct'),
                icon: Icon(Icons.ads_click),
              ),
            ],
            selected: {touchMode},
            onSelectionChanged: (s) => setState(() => _touchMode = s.first),
          ),
          FilterChip(
            label: const Text('Key bar'),
            selected: _showKeyBar,
            onSelected: (v) => setState(() => _showKeyBar = v),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        Expanded(child: _pictureAndKeyBar(viewer, touchMode)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Text(
            'Sent ${stats.sent}  ·  moves coalesced ${stats.movesCoalesced}'
            '  ·  dropped while inactive ${stats.droppedWhileInactive}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// The short layout: no app bar and no stats; one strip of buttons
  /// beside the picture (above it when the screen is taller than wide).
  Widget _compact(RemoteInputViewer viewer) {
    final touchMode = _touchMode ?? _defaultTouchMode;
    return LayoutBuilder(
      builder: (context, box) {
        final beside = box.maxWidth >= box.maxHeight;
        final strip = _ControlStrip(
          axis: beside ? Axis.vertical : Axis.horizontal,
          children: [
            Tooltip(
              message:
                  '${describeState(viewer.state, Side.viewer)}\n'
                  '${_rttText()}',
              child: SessionStateChip(
                state: viewer.state,
                side: Side.viewer,
                iconOnly: true,
              ),
            ),
            SendKeysMenu(viewer: viewer, enabled: viewer.state.isActive),
            PopupMenuButton<void Function()>(
              tooltip: 'View options',
              icon: const Icon(Icons.tune),
              onSelected: (apply) => setState(apply),
              itemBuilder: (context) => [
                for (final (mode, label) in _keyboardModes)
                  CheckedPopupMenuItem(
                    value: () => _keyboardMode = mode,
                    checked: _keyboardMode == mode,
                    child: Text('Keys: $label'),
                  ),
                const PopupMenuDivider(),
                for (final (mode, label) in [
                  (TouchMode.trackpad, 'Touch: trackpad'),
                  (TouchMode.direct, 'Touch: direct'),
                ])
                  CheckedPopupMenuItem(
                    value: () => _touchMode = mode,
                    checked: touchMode == mode,
                    child: Text(label),
                  ),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: () => _showKeyBar = !_showKeyBar,
                  checked: _showKeyBar,
                  child: const Text('Key bar'),
                ),
              ],
            ),
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.link_off),
              onPressed: _disconnect,
            ),
          ],
        );
        return Flex(
          direction: beside ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            strip,
            Expanded(child: _pictureAndKeyBar(viewer, touchMode)),
          ],
        );
      },
    );
  }

  /// The picture, with the key bar under it while the picture keeps
  /// [ViewerPage.minCaptureShare] of the page's height.
  Widget _pictureAndKeyBar(RemoteInputViewer viewer, TouchMode touchMode) {
    final page =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) {
        final keyBar =
            _showKeyBar &&
            box.maxHeight - _keyBarHeight >= ViewerPage.minCaptureShare * page;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _picture(viewer, touchMode)),
            if (keyBar) KeyBarView(viewer: viewer),
          ],
        );
      },
    );
  }

  Widget _picture(RemoteInputViewer viewer, TouchMode touchMode) {
    final state = viewer.state;
    final surface = viewer.surface;
    return Stack(
      // Keeps the capture's state (its focus, and so the soft keyboard)
      // when the layout folds or unfolds around it.
      key: _pictureKey,
      fit: StackFit.expand,
      children: [
        CaptureView(
          viewer: viewer,
          contentSize: surface?.pixelSize,
          keyboardMode: _keyboardMode,
          touchMode: touchMode,
          child: RemotePlaceholder(pixelSize: surface?.pixelSize),
        ),
        if (state.isStopped)
          ColoredBox(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(8),
              // Scaled down, never cut, however short the picture is.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          describeState(state, Side.viewer),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _disconnect,
                          child: const Text('Back'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _rttText() =>
      'RTT ${formatRtt(_viewer?.stats.roundTripTime)}'
      '${_rtt.count < 5 ? '' : '  (p50 ${formatRtt(_rtt.percentile(50))}, '
                'p95 ${formatRtt(_rtt.percentile(95))}, '
                'last ${_rtt.count} s)'}';

  static const List<(KeyboardMode, String)> _keyboardModes = [
    (KeyboardMode.auto, 'auto'),
    (KeyboardMode.physical, 'physical'),
    (KeyboardMode.text, 'text'),
  ];

  /// `RemoteKeyBar`'s default height.
  static const double _keyBarHeight = 44;
}

/// The short layout's buttons in a strip along [axis], with compact
/// buttons. Buttons that don't fit wrap into a second column (or row)
/// rather than scroll out of sight: a landscape phone with its keyboard up
/// has room for two buttons in height.
class _ControlStrip extends StatelessWidget {
  const _ControlStrip({required this.axis, required this.children});

  final Axis axis;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Theme(
        data: theme.copyWith(visualDensity: VisualDensity.compact),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Wrap(
            direction: axis,
            spacing: 2,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      ),
    );
  }
}
