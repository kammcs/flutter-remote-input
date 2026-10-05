import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

// USB HID usages the virtual desktop understands (keyboard page 0x07).
const int _keyA = 0x00070004;
const int _keyC = 0x00070006;
const int _keyV = 0x00070019;
const int _keyZ = 0x0007001D;
const int _key1 = 0x0007001E;
const int _key0 = 0x00070027;
const int _enter = 0x00070028;
const int _escape = 0x00070029;
const int _backspace = 0x0007002A;
const int _tab = 0x0007002B;
const int _space = 0x0007002C;
const int _delete = 0x0007004C;

/// A click, drawn as a ripple where it landed.
final class ClickMark {
  /// Creates a mark.
  const ClickMark(this.id, this.at, this.button, this.clickCount);

  /// Unique per desktop, for the ripple's animation.
  final int id;

  /// Where, in the desktop's local coordinates.
  final Offset at;

  /// Which button.
  final PointerButton button;

  /// 2 for the second press of a double click.
  final int clickCount;
}

/// The presenter's desktop in the one-machine demo: a model of what a
/// [RecordingInjector] was asked to inject, so it can be drawn.
///
/// Its points are in the shared display's desktop coordinates
/// ([DisplayInfo.bounds]), as an injector gets them. What is typed is kept
/// only to be drawn, never logged (`docs/design.md` §6.6).
class VirtualDesktop extends ChangeNotifier {
  /// Creates a desktop for the display at [bounds], looking like
  /// [presenter]'s OS.
  VirtualDesktop({required this.bounds, required this.presenter})
    : cursor = bounds.size.center(Offset.zero);

  /// The shared display's bounds, in desktop coordinates.
  final Rect bounds;

  /// Which OS the desktop pretends to be: its shortcuts use Command on
  /// macOS and Control on Windows.
  final PeerPlatform presenter;

  /// The desktop's size; everything below is in local coordinates, from
  /// the display's top-left corner.
  Size get size => bounds.size;

  Rect _fraction(double l, double t, double w, double h) => Rect.fromLTWH(
    l * size.width,
    t * size.height,
    w * size.width,
    h * size.height,
  );

  /// The "Notes" window, which receives keys and text.
  Rect get notesRect => _fraction(0.05, 0.11, 0.52, 0.48);

  /// The "Click me" button.
  Rect get buttonRect => _fraction(0.05, 0.66, 0.24, 0.16);

  /// The scrollable "List" window.
  Rect get listRect => _fraction(0.62, 0.11, 0.33, 0.76);

  /// The height of one row in the list.
  double get rowHeight => size.height * 0.06;

  /// Rows in the list.
  static const int rowCount = 60;

  /// The pointer.
  Offset cursor;

  /// The buttons held now.
  final Set<PointerButton> heldButtons = {};

  /// Recent clicks.
  final List<ClickMark> clicks = [];
  int _clickIds = 0;

  /// Recent drag paths, oldest first; the last is the one in progress
  /// while the left button is held.
  final List<List<Offset>> trails = [];

  /// Left clicks on the button, and double clicks among them.
  int buttonClicks = 0, buttonDoubleClicks = 0;

  /// The list's scroll offset.
  double scrollOffset = 0;

  /// The Notes window's text.
  String text = '';
  bool _allSelected = false;
  String _clipboard = '';
  final List<String> _undo = [];

  /// Whether the Notes text is selected (after select-all).
  bool get allSelected => _allSelected;

  /// The modifier keys held (HID usages).
  final Set<int> heldModifiers = {};

  /// The last shortcut the desktop acted on, such as "Copy".
  String? lastShortcut;

  /// Increments each time the person at the presenter "touches" their own
  /// mouse, for the demo's local-input notice.
  int localInputs = 0;

  /// Events injected so far.
  int injected = 0;

  /// Applies one injected event. Used as [RecordingInjector.onInject].
  InjectResult apply(InjectedEvent event) {
    injected++;
    switch (event) {
      case InjectedMove(:final point):
        _moveTo(point - bounds.topLeft);
      case InjectedButton(:final point, :final button, :final down):
        _button(point - bounds.topLeft, button, down, event.clickCount);
      case InjectedWheel(:final point, :final dy, :final unit):
        if (listRect.contains(point - bounds.topLeft)) {
          final pixels = unit == WheelUnit.line ? dy * rowHeight : dy * 1.0;
          final max = rowCount * rowHeight - (listRect.height * 0.86);
          scrollOffset = (scrollOffset + pixels).clamp(0, max);
        }
      case InjectedKey(:final usage, :final down):
        down ? _keyDown(usage) : heldModifiers.remove(usage);
      case InjectedText(text: final typed):
        _type(typed);
    }
    notifyListeners();
    return InjectResult.injected;
  }

  /// Shows that the person at the presenter used their own mouse.
  void noteLocalInput() {
    localInputs++;
    notifyListeners();
  }

  void _moveTo(Offset p) {
    cursor = p;
    if (heldButtons.contains(PointerButton.left) && trails.isNotEmpty) {
      final trail = trails.last;
      if (trail.isEmpty || (trail.last - p).distance > 2) trail.add(p);
      if (trail.length > 400) trail.removeAt(0);
    }
  }

  void _button(Offset p, PointerButton button, bool down, int clickCount) {
    cursor = p;
    if (!down) {
      heldButtons.remove(button);
      return;
    }
    heldButtons.add(button);
    clicks.add(ClickMark(_clickIds++, p, button, clickCount));
    if (clicks.length > 6) clicks.removeAt(0);
    if (button == PointerButton.left) {
      trails.add([p]);
      if (trails.length > 3) trails.removeAt(0);
      if (buttonRect.contains(p)) {
        buttonClicks++;
        if (clickCount >= 2) buttonDoubleClicks++;
      }
    }
  }

  bool get _commandHeld => heldModifiers.any(
    (u) => presenter == PeerPlatform.macos
        ? u == HidModifier.metaLeft || u == HidModifier.metaRight
        : u == HidModifier.controlLeft || u == HidModifier.controlRight,
  );

  bool get _shiftHeld =>
      heldModifiers.contains(HidModifier.shiftLeft) ||
      heldModifiers.contains(HidModifier.shiftRight);

  void _keyDown(int usage) {
    if (HidModifier.isModifier(usage)) {
      heldModifiers.add(usage);
      return;
    }
    if (_commandHeld) {
      switch (usage) {
        case _keyA:
          _allSelected = true;
          lastShortcut = 'Select all';
        case _keyC:
          if (_allSelected) _clipboard = text;
          lastShortcut = 'Copy';
        case _keyV:
          _type(_clipboard);
          lastShortcut = 'Paste';
        case _keyZ:
          if (_undo.isNotEmpty) text = _undo.removeLast();
          _allSelected = false;
          lastShortcut = 'Undo';
      }
      return;
    }
    switch (usage) {
      case _backspace || _delete:
        _edit(
          _allSelected
              ? ''
              : (text.characters.isEmpty
                    ? text
                    : text.characters.skipLast(1).string),
        );
      case _enter:
        _type('\n');
      case _tab:
        _type('    ');
      case _escape:
        _allSelected = false;
      default:
        // Physical keys in "physical" keyboard mode, typed as a US layout.
        final char = _usLayout(usage);
        if (char != null) _type(char);
    }
  }

  String? _usLayout(int usage) {
    if (usage >= _keyA && usage < _keyA + 26) {
      final c = String.fromCharCode(0x61 + usage - _keyA);
      return _shiftHeld ? c.toUpperCase() : c;
    }
    if (usage >= _key1 && usage <= _key0) {
      return usage == _key0 ? '0' : String.fromCharCode(0x31 + usage - _key1);
    }
    if (usage == _space) return ' ';
    return null;
  }

  void _type(String typed) {
    if (typed.isEmpty) return;
    _edit(_allSelected ? typed : text + typed);
  }

  void _edit(String next) {
    if (next == text && !_allSelected) return;
    _undo.add(text);
    if (_undo.length > 20) _undo.removeAt(0);
    _allSelected = false;
    // Keep the demo bounded: the end of a long text is what's shown.
    text = next.length > 4000 ? next.substring(next.length - 4000) : next;
  }
}

/// Draws a [VirtualDesktop], fitted into the space it's given (letterboxed,
/// like a video view with `BoxFit.contain`).
class VirtualDesktopView extends StatelessWidget {
  /// Creates a view of [desktop].
  const VirtualDesktopView({super.key, required this.desktop});

  /// The desktop.
  final VirtualDesktop desktop;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
        child: FittedBox(
          child: SizedBox.fromSize(
            size: desktop.size,
            child: ListenableBuilder(
              listenable: desktop,
              builder: (context, _) => _DesktopContents(desktop: desktop),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopContents extends StatelessWidget {
  const _DesktopContents({required this.desktop});

  final VirtualDesktop desktop;

  @override
  Widget build(BuildContext context) {
    final d = desktop;
    final u = d.size.height / 100; // One unit: 1 % of the height.
    final mac = d.presenter == PeerPlatform.macos;
    final body = TextStyle(fontSize: 2.6 * u, color: Colors.black87);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: mac
                      ? const [Color(0xFF3A1C71), Color(0xFFD76D77)]
                      : const [Color(0xFF0F2027), Color(0xFF2C77A8)],
                ),
              ),
            ),
          ),
          if (mac)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 3.4 * u,
              child: _Bar(u: u, label: '  Finder   File   Edit   View'),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 5 * u,
              child: _Bar(u: u, label: '  ⊞   Search   Notes   List'),
            ),
          _Window(
            rect: d.notesRect,
            title: 'Notes',
            u: u,
            mac: mac,
            child: Padding(
              padding: EdgeInsets.all(1.5 * u),
              child: Align(
                alignment: Alignment.topLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: d.allSelected
                        ? Colors.lightBlue.withValues(alpha: 0.35)
                        : null,
                  ),
                  child: Text(
                    '${d.text}▍',
                    key: const ValueKey('notes-text'),
                    style: body.copyWith(fontFamily: 'monospace'),
                    maxLines: 9,
                    overflow: TextOverflow.fade,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: d.buttonRect,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32),
                borderRadius: BorderRadius.circular(1.5 * u),
                boxShadow: [
                  BoxShadow(blurRadius: 2 * u, color: Colors.black38),
                ],
              ),
              child: Center(
                child: Text(
                  'Click me\n${d.buttonClicks} clicks · '
                  '${d.buttonDoubleClicks} double',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 3 * u, color: Colors.white),
                ),
              ),
            ),
          ),
          _Window(
            rect: d.listRect,
            title: 'List (scroll me)',
            u: u,
            mac: mac,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -d.scrollOffset,
                    child: Column(
                      children: [
                        for (var i = 1; i <= VirtualDesktop.rowCount; i++)
                          Container(
                            height: d.rowHeight,
                            alignment: Alignment.centerLeft,
                            padding: EdgeInsets.symmetric(horizontal: 2 * u),
                            color: i.isEven ? const Color(0xFFF2F4F7) : null,
                            child: Text('Row $i', style: body),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: d.buttonRect.right + 3 * u,
            top: d.buttonRect.top,
            width: d.notesRect.right - d.buttonRect.right - 3 * u,
            child: _KeyStatus(desktop: d, u: u),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _TrailPainter(d.trails, u)),
            ),
          ),
          for (final click in d.clicks)
            Positioned(
              key: ValueKey('click-${click.id}'),
              left: click.at.dx - 6 * u,
              top: click.at.dy - 6 * u,
              width: 12 * u,
              height: 12 * u,
              child: ClickRipple(mark: click),
            ),
          if (d.localInputs > 0)
            Positioned(
              left: 0,
              right: 0,
              top: 6 * u,
              child: _LocalInputNotice(key: ValueKey(d.localInputs), u: u),
            ),
          Positioned(
            left: d.cursor.dx,
            top: d.cursor.dy,
            width: 4 * u,
            height: 6 * u,
            child: const IgnorePointer(
              child: CustomPaint(painter: _CursorPainter()),
            ),
          ),
        ],
      ),
    );
  }
}

/// A fading ring where a click landed.
class ClickRipple extends StatelessWidget {
  /// Creates a ripple for [mark].
  const ClickRipple({super.key, required this.mark});

  /// The click.
  final ClickMark mark;

  @override
  Widget build(BuildContext context) {
    final color = switch (mark.button) {
      PointerButton.left => Colors.amberAccent,
      PointerButton.right => Colors.lightBlueAccent,
      _ => Colors.white,
    };
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      builder: (context, t, _) => Opacity(
        opacity: 1 - t,
        child: Transform.scale(
          scale: 0.3 + 0.7 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: color,
                width: mark.clickCount >= 2 ? 10 : 5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.u, required this.label});

  final double u;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.45),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(fontSize: 2 * u, color: Colors.white),
        ),
      ),
    );
  }
}

class _Window extends StatelessWidget {
  const _Window({
    required this.rect,
    required this.title,
    required this.u,
    required this.mac,
    required this.child,
  });

  final Rect rect;
  final String title;
  final double u;
  final bool mac;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dots = [
      for (final c in const [Colors.red, Colors.amber, Colors.green])
        Padding(
          padding: EdgeInsets.only(right: 0.8 * u),
          child: CircleAvatar(radius: 0.8 * u, backgroundColor: c),
        ),
    ];
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(1.2 * u),
          boxShadow: [BoxShadow(blurRadius: 3 * u, color: Colors.black45)],
        ),
        child: Column(
          children: [
            Container(
              height: 4.5 * u,
              padding: EdgeInsets.symmetric(horizontal: 1.5 * u),
              decoration: BoxDecoration(
                color: const Color(0xFFE6E8EC),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(1.2 * u),
                ),
              ),
              child: Row(
                children: [
                  if (mac) ...dots,
                  Expanded(
                    child: Text(
                      title,
                      textAlign: mac ? TextAlign.center : TextAlign.start,
                      style: TextStyle(fontSize: 2.2 * u),
                    ),
                  ),
                  if (!mac) Text('─  ☐  ✕', style: TextStyle(fontSize: 2 * u)),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _KeyStatus extends StatelessWidget {
  const _KeyStatus({required this.desktop, required this.u});

  final VirtualDesktop desktop;
  final double u;

  static String _name(int usage) => switch (usage) {
    HidModifier.controlLeft || HidModifier.controlRight => 'Ctrl',
    HidModifier.shiftLeft || HidModifier.shiftRight => 'Shift',
    HidModifier.altLeft || HidModifier.altRight => 'Alt',
    HidModifier.metaLeft || HidModifier.metaRight => 'Meta',
    _ => '?',
  };

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 2.4 * u, color: Colors.white);
    final held = desktop.heldModifiers.map(_name).toSet().join(' + ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Held: ${held.isEmpty ? 'none' : held}', style: style),
        if (desktop.lastShortcut != null)
          Text('Last shortcut: ${desktop.lastShortcut}', style: style),
        Text('Scrolled: ${desktop.scrollOffset.round()} px', style: style),
      ],
    );
  }
}

class _LocalInputNotice extends StatelessWidget {
  const _LocalInputNotice({super.key, required this.u});

  final double u;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 1500),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.orange.shade800,
            borderRadius: BorderRadius.circular(3 * u),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 3 * u, vertical: u),
            child: Text(
              'The presenter used their own mouse: local input wins',
              style: TextStyle(fontSize: 2.6 * u, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  _TrailPainter(this.trails, this.u);

  final List<List<Offset>> trails;
  final double u;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < trails.length; i++) {
      final trail = trails[i];
      if (trail.length < 2) continue;
      final paint = Paint()
        ..color = Colors.amberAccent.withValues(
          alpha: 0.35 + 0.5 * (i + 1) / trails.length,
        )
        ..strokeWidth = 0.6 * u
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(Path()..addPolygon(trail, false), paint);
    }
  }

  @override
  bool shouldRepaint(_TrailPainter old) => true;
}

class _CursorPainter extends CustomPainter {
  const _CursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h * 0.8)
      ..lineTo(w * 0.28, h * 0.6)
      ..lineTo(w * 0.5, h)
      ..lineTo(w * 0.66, h * 0.93)
      ..lineTo(w * 0.45, h * 0.55)
      ..lineTo(w * 0.8, h * 0.52)
      ..close();
    canvas
      ..drawPath(arrow, Paint()..color = Colors.black)
      ..drawPath(
        arrow,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.08,
      );
  }

  @override
  bool shouldRepaint(_CursorPainter old) => false;
}
