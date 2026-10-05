part of 'capture.dart';

/// A row of the keys a soft keyboard lacks, for phones and tablets
/// (`docs/design.md` §8): Escape, Tab, sticky Ctrl, Alt, Shift and the
/// host's Command or Windows key, the arrows, Home, End, Page Up and Page
/// Down, Delete, F1 to F12, a "Send keys" menu for shortcuts the viewer's
/// own OS would take (Alt+Tab, Command+Tab, the Windows key, Command+Space,
/// Ctrl+Esc), and a button that shows and hides the soft keyboard.
///
/// Keys are labelled as the **host's** keyboard has them, and sent so the
/// host receives them as labelled: with the host's default
/// [ModifierMapping.auto], which swaps Control and Meta when exactly one
/// end is an Apple platform, the bar swaps them first. Pass the host's
/// [hostModifierMapping] if it isn't the default. (Ctrl+Alt+Del can't be
/// injected, so it isn't offered.)
///
/// A modifier tapped once is **latched**: held on the host until the next
/// key, click or text. Tapped again it's **locked** until a third tap.
/// Pass the same [controller] to the [RemoteInputCapture] so latched
/// modifiers apply to typing and clicks there, and for the keyboard
/// button. Arrow keys and Delete repeat while held.
///
/// While the viewer's session isn't active the keys are disabled (only the
/// keyboard button works), and sticky modifiers are let go: the host
/// releases everything when the session stops.
class RemoteKeyBar extends StatefulWidget {
  /// Creates a key bar sending through [viewer].
  const RemoteKeyBar({
    super.key,
    required this.viewer,
    this.controller,
    this.showKeyboardToggle = true,
    this.showFunctionKeys = true,
    this.showSendKeysMenu = true,
    this.hostModifierMapping = ModifierMapping.auto,
    this.height = 44,
  });

  /// The viewer that sends the keys.
  final RemoteInputViewer viewer;

  /// The controller shared with a [RemoteInputCapture]: sticky modifiers
  /// and the soft keyboard. Without one, sticky modifiers apply only to the
  /// bar's own keys, and there's no keyboard button.
  final RemoteInputCaptureController? controller;

  /// Whether to show the button that shows and hides the soft keyboard
  /// (needs [controller]).
  final bool showKeyboardToggle;

  /// Whether to show F1 to F12.
  final bool showFunctionKeys;

  /// Whether to show the "Send keys" menu.
  final bool showSendKeysMenu;

  /// The host's `HostOptions.modifierMapping`, which decides whether keys
  /// are swapped before sending so they arrive as labelled.
  final ModifierMapping hostModifierMapping;

  /// The bar's height.
  final double height;

  @override
  State<RemoteKeyBar> createState() => _RemoteKeyBarState();
}

class _RemoteKeyBarState extends State<RemoteKeyBar> {
  static const Duration _repeatInterval = Duration(milliseconds: 50);

  RemoteInputCaptureController? _ownController;
  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<RemoteSurface?>? _surfaceSubscription;
  Timer? _repeatTimer;
  int? _repeatUsage;
  final MenuController _menu = MenuController();

  RemoteInputCaptureController get _controller =>
      widget.controller ?? (_ownController ??= RemoteInputCaptureController());

  RemoteInputViewer get _viewer => widget.viewer;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(RemoteKeyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewer, widget.viewer)) {
      _stopRepeat(oldWidget.viewer);
      _unsubscribe();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _stopRepeat(_viewer);
    _unsubscribe();
    _ownController?.dispose();
    super.dispose();
  }

  void _subscribe() {
    _controller._viewer ??= widget.viewer;
    // The host's platform arrives with its handshake, with the surface.
    void rebuild(Object? _) {
      if (mounted) setState(() {});
    }

    _stateSubscription = widget.viewer.stateChanges.listen((state) {
      if (!state.isActive) {
        // The host has released everything: so does the bar.
        _stopRepeat(widget.viewer);
        _controller._forgetSticky();
        if (_menu.isOpen) _menu.close();
      }
      rebuild(state);
    });
    _surfaceSubscription = widget.viewer.surfaceChanges.listen(rebuild);
  }

  void _unsubscribe() {
    _stateSubscription?.cancel();
    _surfaceSubscription?.cancel();
  }

  /// Whether the host swaps Control and Meta, so the bar must swap them
  /// first for keys to arrive as labelled.
  bool get _swap {
    final host = _viewer.hostPlatform;
    return widget.hostModifierMapping == ModifierMapping.auto &&
        host != null &&
        host != PeerPlatform.unknown &&
        host.isApple != _viewer.platform.isApple;
  }

  /// The usage to send for the host's key [hostUsage].
  int _toSend(int hostUsage) =>
      _swap ? swapControlMetaUsage(hostUsage) : hostUsage;

  void _press(int usage) {
    final bits = _controller._bits;
    _viewer
      ..key(usage, KeyAction.down, modifiers: bits)
      ..key(usage, KeyAction.up, modifiers: bits);
    _controller._consumeOneShot();
  }

  void _startRepeat(int usage) {
    _stopRepeat(_viewer);
    _repeatUsage = usage;
    _viewer.key(usage, KeyAction.down, modifiers: _controller._bits);
    _repeatTimer = Timer.periodic(_repeatInterval, (_) {
      _viewer.key(usage, KeyAction.repeat, modifiers: _controller._bits);
    });
  }

  void _stopRepeat(RemoteInputViewer viewer) {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    final usage = _repeatUsage;
    if (usage == null) return;
    _repeatUsage = null;
    viewer.key(usage, KeyAction.up, modifiers: _controller._bits);
    _controller._consumeOneShot();
  }

  void _sendShortcut(List<int> hostUsages) {
    _menu.close();
    // Modifiers held on the host (a locked sticky Ctrl, a Shift held on a
    // hardware keyboard) stay in every key's state, so the host's drift
    // correction doesn't release them.
    _viewer.sendShortcut([
      for (final u in hostUsages) _toSend(u),
    ], heldModifiers: _controller._bits);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => _buildBar(context),
  );

  Widget _buildBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final host = _viewer.hostPlatform;
    final mac = host == PeerPlatform.macos;
    final windows = host == PeerPlatform.windows;
    final active = _viewer.state.isActive;
    final controller = _controller;

    Widget key(
      String label,
      int usage, {
      String? semantics,
      bool repeat = false,
    }) => _KeyButton(
      label: label,
      semanticsLabel: semantics,
      enabled: active,
      onTap: () => _press(usage),
      onHoldStart: repeat ? () => _startRepeat(usage) : null,
      onHoldEnd: repeat ? () => _stopRepeat(_viewer) : null,
    );

    Widget modifier(String label, int hostUsage, String semantics) {
      final usage = _toSend(hostUsage);
      final state = controller.stickyModifier(usage);
      return _KeyButton(
        label: label,
        semanticsLabel: semantics,
        enabled: active,
        selected: state != StickyModifierState.off,
        locked: state == StickyModifierState.locked,
        onTap: () => controller.toggleStickyModifier(usage),
      );
    }

    final shortcuts = <(String, List<int>)>[
      if (!mac) ('Alt+Tab', [HidModifier.altLeft, HidKey.tab]),
      if (!windows) ('Cmd+Tab', [HidModifier.metaLeft, HidKey.tab]),
      if (!mac) ('Win', [HidModifier.metaLeft]),
      if (!windows) ('Cmd+Space', [HidModifier.metaLeft, HidKey.space]),
      if (!mac) ('Ctrl+Esc', [HidModifier.controlLeft, HidKey.escape]),
      if (windows) ('Alt+F4', [HidModifier.altLeft, HidKey.f4]),
    ];

    final keys = <Widget>[
      if (widget.showKeyboardToggle && widget.controller != null)
        _KeyButton(
          icon: controller.isSoftKeyboardRequested
              ? Icons.keyboard_hide
              : Icons.keyboard,
          semanticsLabel: controller.isSoftKeyboardRequested
              ? 'Hide keyboard'
              : 'Show keyboard',
          onTap: controller.toggleSoftKeyboard,
        ),
      key('Esc', HidKey.escape, semantics: 'Escape'),
      key('Tab', HidKey.tab),
      modifier(mac ? '⌃ ctrl' : 'Ctrl', HidModifier.controlLeft, 'Control'),
      modifier(
        mac ? '⌥ opt' : 'Alt',
        HidModifier.altLeft,
        mac ? 'Option' : 'Alt',
      ),
      modifier(mac ? '⇧ shift' : 'Shift', HidModifier.shiftLeft, 'Shift'),
      modifier(
        mac ? '⌘ cmd' : (windows ? 'Win' : 'Meta'),
        HidModifier.metaLeft,
        mac ? 'Command' : (windows ? 'Windows key' : 'Meta'),
      ),
      key('←', HidKey.arrowLeft, semantics: 'Left arrow', repeat: true),
      key('↑', HidKey.arrowUp, semantics: 'Up arrow', repeat: true),
      key('↓', HidKey.arrowDown, semantics: 'Down arrow', repeat: true),
      key('→', HidKey.arrowRight, semantics: 'Right arrow', repeat: true),
      key('Home', HidKey.home),
      key('End', HidKey.end),
      key('PgUp', HidKey.pageUp, semantics: 'Page up'),
      key('PgDn', HidKey.pageDown, semantics: 'Page down'),
      key(
        mac ? '⌦ Del' : 'Del',
        HidKey.delete,
        semantics: 'Delete',
        repeat: true,
      ),
      if (widget.showFunctionKeys)
        for (var n = 1; n <= 12; n++) key('F$n', HidKey.function(n)),
      if (widget.showSendKeysMenu)
        MenuAnchor(
          controller: _menu,
          menuChildren: [
            for (final (label, usages) in shortcuts)
              MenuItemButton(
                onPressed: active ? () => _sendShortcut(usages) : null,
                child: Text(label),
              ),
          ],
          child: _KeyButton(
            label: 'Keys…',
            semanticsLabel: 'Send keys',
            enabled: active,
            onTap: () => _menu.isOpen ? _menu.close() : _menu.open(),
          ),
        ),
    ];

    return Material(
      color: scheme.surfaceContainerHigh,
      child: SizedBox(
        height: widget.height,
        child: Opacity(
          opacity: active ? 1 : 0.5,
          // The bar never takes focus from the capture.
          child: ExcludeFocus(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: keys),
            ),
          ),
        ),
      ),
    );
  }
}

/// One key of a [RemoteKeyBar]. A tap calls [onTap]; when [onHoldStart] is
/// set, a long press calls it, and [onHoldEnd] when it ends. A disabled key
/// takes no new presses.
class _KeyButton extends StatefulWidget {
  const _KeyButton({
    this.label,
    this.icon,
    this.semanticsLabel,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.enabled = true,
    this.selected = false,
    this.locked = false,
  });

  final String? label;
  final IconData? icon;
  final String? semanticsLabel;
  final VoidCallback onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  final bool enabled;
  final bool selected;
  final bool locked;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _down = false;

  void _setDown(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = widget.selected
        ? scheme.primary
        : _down
        ? scheme.surfaceContainerHighest
        : scheme.surface;
    final foreground = widget.selected ? scheme.onPrimary : scheme.onSurface;
    final hold = widget.onHoldStart;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.semanticsLabel ?? widget.label,
      excludeSemantics: true,
      // A hold already under way still ends: the press was hit-tested
      // before the key was disabled.
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setDown(true),
          onTapUp: (_) => _setDown(false),
          onTapCancel: () => _setDown(false),
          onTap: widget.onTap,
          onLongPressStart: hold == null
              ? null
              : (_) {
                  _setDown(true);
                  hold();
                },
          onLongPressEnd: hold == null
              ? null
              : (_) {
                  _setDown(false);
                  widget.onHoldEnd?.call();
                },
          onLongPressCancel: hold == null
              ? null
              : () {
                  _setDown(false);
                  widget.onHoldEnd?.call();
                },
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: widget.locked ? scheme.onPrimary : scheme.outlineVariant,
                width: widget.locked ? 2 : 1,
              ),
            ),
            child: widget.icon != null
                ? Icon(widget.icon, size: 20, color: foreground)
                : Text(
                    widget.label ?? '',
                    style: TextStyle(color: foreground, fontSize: 14),
                  ),
          ),
        ),
      ),
    );
  }
}
