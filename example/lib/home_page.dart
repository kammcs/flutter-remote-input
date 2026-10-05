import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

import 'demo/demo_page.dart';
import 'host/host_page.dart';
import 'viewer/viewer_page.dart';

/// Picks a role: host this computer, control another, or the one-machine
/// demo.
class HomePage extends StatelessWidget {
  /// Creates the home screen.
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canHost = !RemoteInputHost.limitations.contains(
      HostLimitation.unsupportedPlatform,
    );
    void open(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));

    final roles = [
      _RoleCard(
        key: const ValueKey('role-demo'),
        icon: Icons.science_outlined,
        title: 'One-machine demo',
        badge: 'Start here',
        description:
            'Host and viewer on this device, with a drawn desktop: click, '
            'drag, scroll and type in one view, and watch it injected in the '
            'other. Nothing is injected for real.',
        onTap: () => open(const DemoPage()),
      ),
      _RoleCard(
        key: const ValueKey('role-viewer'),
        icon: Icons.cast_connected,
        title: 'Control another computer',
        description:
            'Use this device\'s mouse, keyboard or touch to control a '
            'Windows PC or a Mac running this example as the host.',
        onTap: () => open(const ViewerPage()),
      ),
      _RoleCard(
        key: const ValueKey('role-host'),
        icon: Icons.desktop_windows_outlined,
        title: 'Host this computer',
        description: canHost
            ? (RemoteInputHost.isSupported
                  ? 'Let a viewer on another device control this computer, '
                        'after you allow it.'
                  : 'Let a viewer control this computer. Injection on this '
                        'OS arrives with a later milestone: see what\'s '
                        'missing.')
            : HostLimitation.unsupportedPlatform.description,
        onTap: canHost ? () => open(const HostPage()) : null,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('remote_input example')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Remote keyboard and mouse control',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Any device can control a Windows or macOS desktop. '
                        'Protocol version $remoteInputProtocolVersion.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      if (wide)
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final (i, r) in roles.indexed) ...[
                                if (i > 0) const SizedBox(width: 12),
                                Expanded(child: r),
                              ],
                            ],
                          ),
                        )
                      else
                        for (final (i, r) in roles.indexed) ...[
                          if (i > 0) const SizedBox(height: 12),
                          r,
                        ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 32, color: theme.colorScheme.primary),
                    const Spacer(),
                    if (badge != null)
                      Chip(
                        label: Text(badge!),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(description, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
