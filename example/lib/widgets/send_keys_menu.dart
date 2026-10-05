import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

const int _tab = 0x0007002B;
const int _space = 0x0007002C;
const int _escape = 0x00070029;
const int _keyC = 0x00070006;
const int _keyV = 0x00070019;
const int _keyZ = 0x0007001D;

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
    if (text != null && text.isNotEmpty) viewer.text(text);
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
          viewer.sendShortcut(_shortcuts[i].$2);
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
          hintText: 'Typed by Unicode, whatever the keyboard layouts',
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
