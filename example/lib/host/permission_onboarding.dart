// macOS Accessibility onboarding for the host (docs/design.md §7.3).
//
// Whether the permission is missing comes from the host:
// `RemoteInputHost.checkAvailable()` returns
// `HostUnavailableReason.permissionDenied` (the host screen checks it).
// `RemoteInputPermissions` asks for it, opens System Settings and reports the
// grant. Never call them from tests: `request()` shows a system prompt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

/// Shows macOS's prompt to allow this app to control the computer (the
/// first time only; after that, people use System Settings).
Future<void> requestPermission() async {
  await RemoteInputPermissions.request();
}

/// Opens System Settings at Privacy & Security → Accessibility.
Future<void> openPermissionSettings() async {
  await RemoteInputPermissions.openSettings();
}

/// Explains the Accessibility permission and helps grant it. Shown by the
/// host screen while the host reports the permission missing.
class PermissionOnboarding extends StatefulWidget {
  /// Creates the onboarding card. [onCheckAgain] re-checks the permission;
  /// it's also called when macOS reports the grant. [watch] follows
  /// `RemoteInputPermissions.statusChanges` (off in tests).
  const PermissionOnboarding({
    super.key,
    required this.onCheckAgain,
    this.watch = true,
  });

  /// Called to check the permission again.
  final VoidCallback onCheckAgain;

  /// Whether to follow the permission's status while shown.
  final bool watch;

  @override
  State<PermissionOnboarding> createState() => _PermissionOnboardingState();
}

class _PermissionOnboardingState extends State<PermissionOnboarding> {
  StreamSubscription<RemoteInputPermissionStatus>? _status;

  @override
  void initState() {
    super.initState();
    if (widget.watch) {
      _status = RemoteInputPermissions.statusChanges.listen((s) {
        if (s == RemoteInputPermissionStatus.granted) widget.onCheckAgain();
      });
    }
  }

  @override
  void dispose() {
    _status?.cancel();
    super.dispose();
  }

  VoidCallback get onCheckAgain => widget.onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.accessibility_new),
                const SizedBox(width: 8),
                Text(
                  'Allow this app to control the computer',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'macOS lets an app post mouse and keyboard events only with '
              'the Accessibility permission. Turn this app on in System '
              'Settings → Privacy & Security → Accessibility, then check '
              'again.\n\n'
              'A debug build that is rebuilt may count as a new app and need '
              'the permission again.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () async {
                    await requestPermission();
                    onCheckAgain();
                  },
                  child: const Text('Ask macOS'),
                ),
                OutlinedButton(
                  onPressed: openPermissionSettings,
                  child: const Text('Open System Settings'),
                ),
                TextButton(
                  onPressed: onCheckAgain,
                  child: const Text('Check again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
