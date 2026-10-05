import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

void main() {
  runApp(const RemoteInputExampleApp());
}

/// The example app's shell. Milestone M6 (`docs/roadmap.md`) turns it into
/// a host that injects and a viewer that captures, on two machines.
class RemoteInputExampleApp extends StatelessWidget {
  /// Creates the app.
  const RemoteInputExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'remote_input example',
      home: Scaffold(
        appBar: AppBar(title: const Text('remote_input example')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Protocol version $remoteInputProtocolVersion'),
              SizedBox(height: 8),
              Text(
                'Host (Windows, macOS): shares a surface and injects the '
                "viewer's input. Viewer (any platform): captures input over "
                'the remote view. Both arrive with milestone M6.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
