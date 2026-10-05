// macOS Accessibility onboarding for the host (docs/design.md §7.3).
//
// Whether the permission is missing comes from the package already:
// `RemoteInputHost.checkAvailable()` returns
// `HostUnavailableReason.permissionDenied` (the host screen checks it).
// Asking for it and opening System Settings need `RemoteInputPermissions`,
// which lands with roadmap M3.
//
// TODO(M3): when `RemoteInputPermissions` is exported, fill in the two
// functions below:
//   requestPermission      -> `await RemoteInputPermissions.request();`
//   openPermissionSettings -> `await RemoteInputPermissions.openSettings();`
// and, optionally, have [PermissionOnboarding] listen to
// `RemoteInputPermissions.statusChanges` to call `onCheckAgain` by itself.
// Never call them from tests: they show a system prompt.
import 'package:flutter/material.dart';

/// Shows macOS's prompt to allow this app to control the computer.
Future<void> requestPermission() async {
  // TODO(M3): await RemoteInputPermissions.request();
}

/// Opens System Settings at Privacy & Security → Accessibility.
Future<void> openPermissionSettings() async {
  // TODO(M3): await RemoteInputPermissions.openSettings();
}

/// Whether [requestPermission] and [openPermissionSettings] do anything
/// yet. TODO(M3): remove with the TODOs above.
const bool permissionApiAvailable = false;

/// Explains the Accessibility permission and helps grant it. Shown by the
/// host screen while the host reports the permission missing.
class PermissionOnboarding extends StatelessWidget {
  /// Creates the onboarding card. [onCheckAgain] re-checks the permission.
  const PermissionOnboarding({super.key, required this.onCheckAgain});

  /// Called to check the permission again.
  final VoidCallback onCheckAgain;

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
                  onPressed: permissionApiAvailable
                      ? () async {
                          await requestPermission();
                          onCheckAgain();
                        }
                      : null,
                  child: const Text('Ask macOS'),
                ),
                OutlinedButton(
                  onPressed: permissionApiAvailable
                      ? openPermissionSettings
                      : null,
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
