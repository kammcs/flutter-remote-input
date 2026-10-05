import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

import '../viewer/capture_view.dart';

const int _enter = 0x00070028;
const int _tab = 0x0007002B;
const int _space = 0x0007002C;
const int _escape = 0x00070029;
const int _keyC = 0x00070006;
const int _keyV = 0x00070019;
const int _keyZ = 0x0007001D;

/// What [typeOnHost] typed.
enum TypedText {
  /// All of it.
  all,

  /// The start of it: the rest was past `ViewerOptions.maxTextBytes`.
  cut,

  /// The start of it: control paused or ended on the way.
  interrupted,

  /// Nothing: control isn't active.
  notSent,
}

/// Types [text] on the host, with an Enter key press for each line break.
///
/// Text goes by Unicode, and a line break in it doesn't act as Return on
/// every host, so the lines go as text and the breaks as Enter. All of it
/// counts towards one `ViewerOptions.maxTextBytes`: [onCut] is called at
/// once if the end won't fit. [heldModifiers] are modifiers already held on
/// the host (the key bar's sticky ones), kept held across the Enters.
///
/// Lines are paced at the host's default typing rates ([charsPerSecond],
/// [keysPerSecond]): the host queues at most 64 messages before it stops a
/// session for flooding, and many short lines would overflow it.
Future<TypedText> typeOnHost(
  RemoteInputViewer viewer,
  String text, {
  int heldModifiers = KeyModifiers.none,
  void Function()? onCut,
  int charsPerSecond = 200,
  int keysPerSecond = 60,
}) async {
  if (!viewer.state.isActive) return TypedText.notSent;
  final (kept, cut) = _cutUtf8(
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
    viewer.options.maxTextBytes,
  );
  if (cut) onCut?.call();
  final lines = kept.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!viewer.state.isActive) return TypedText.interrupted;
    final line = lines[i];
    if (i > 0) viewer.sendShortcut([_enter], heldModifiers: heldModifiers);
    if (line.isNotEmpty && !viewer.text(line)) return TypedText.interrupted;
    if (i < lines.length - 1) {
      await Future<void>.delayed(
        Duration(
          microseconds:
              line.runes.length * 1000000 ~/ charsPerSecond +
              2 * 1000000 ~/ keysPerSecond,
        ),
      );
    }
  }
  return cut ? TypedText.cut : TypedText.all;
}

/// [text] up to [maxBytes] of UTF-8, cut between characters, and whether
/// anything was cut. Line breaks count one byte each.
(String, bool) _cutUtf8(String text, int maxBytes) {
  var bytes = 0;
  var end = 0;
  for (final rune in text.runes) {
    final n = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes + n > maxBytes) return (text.substring(0, end), true);
    bytes += n;
    end += rune > 0xFFFF ? 2 : 1;
  }
  return (text, false);
}

/// Shortcuts the viewer's own OS takes before the app sees them (Alt+Tab,
/// Cmd+Space, the Windows key), sent with `viewer.sendShortcut`, and a
/// "Type text" box for devices without a hardware keyboard
/// (`docs/design.md` §5.4).
///
/// Keys go as the viewer's keyboard names them; the host maps Control and
/// Command between a Mac and Windows as it does for typed shortcuts.
class SendKeysMenu extends StatelessWidget {
  /// Creates the menu for [viewer].
  const SendKeysMenu({super.key, required this.viewer, this.enabled = true});

  /// The viewer to send through.
  final RemoteInputViewer viewer;

  /// Whether the menu can be opened.
  final bool enabled;

  static const List<(String, List<int>)> _shortcuts = [
    ('Alt+Tab', [HidModifier.altLeft, _tab]),
    ('Meta+Tab (⌘ Tab / Win+Tab)', [HidModifier.metaLeft, _tab]),
    ('Meta+Space (⌘ Space / Win+Space)', [HidModifier.metaLeft, _space]),
    ('Meta (the Windows key / ⌘)', [HidModifier.metaLeft]),
    ('Escape', [_escape]),
    ('Ctrl+C (copy)', [HidModifier.controlLeft, _keyC]),
    ('Ctrl+V (paste)', [HidModifier.controlLeft, _keyV]),
    ('Ctrl+Z (undo)', [HidModifier.controlLeft, _keyZ]),
  ];

  Future<void> _typeText(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _TypeTextDialog(),
    );
    if (text == null || text.isEmpty || !context.mounted) return;
    // Taken now: typing a long text outlasts this menu if the layout changes.
    final messenger = ScaffoldMessenger.maybeOf(context);
    void tell(String message) =>
        messenger?.showSnackBar(SnackBar(content: Text(message)));
    final result = await typeOnHost(
      viewer,
      text,
      heldModifiers: captureControllerFor(viewer).stickyModifierBits,
      onCut: () =>
          tell('Text was cut to ${viewer.options.maxTextBytes ~/ 1024} KB'),
    );
    switch (result) {
      case TypedText.all || TypedText.cut:
        break;
      case TypedText.interrupted:
        tell('Typing stopped: control paused or ended');
      case TypedText.notSent:
        tell("Not typed: you aren't in control now");
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      enabled: enabled,
      tooltip: 'Send keys',
      icon: const Icon(Icons.keyboard_command_key),
      onSelected: (i) {
        if (i < 0) {
          _typeText(context);
        } else {
          // Keeps the key bar's sticky modifiers held on the host.
          viewer.sendShortcut(
            _shortcuts[i].$2,
            heldModifiers: captureControllerFor(viewer).stickyModifierBits,
          );
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: -1,
          child: ListTile(
            leading: Icon(Icons.keyboard),
            title: Text('Type text…'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        for (var i = 0; i < _shortcuts.length; i++)
          PopupMenuItem(value: i, child: Text(_shortcuts[i].$1)),
      ],
    );
  }
}

class _TypeTextDialog extends StatefulWidget {
  const _TypeTextDialog();

  @override
  State<_TypeTextDialog> createState() => _TypeTextDialogState();
}

class _TypeTextDialogState extends State<_TypeTextDialog> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Type on the host'),
      content: TextField(
        controller: _text,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText:
              'Typed by Unicode, whatever the keyboard layouts; '
              'line breaks as Enter',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Type it'),
        ),
      ],
    );
  }
}
