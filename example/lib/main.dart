import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

import 'home_page.dart';

void main() {
  runApp(const RemoteInputExampleApp());
}

/// The example app: host this computer, control another one, or try both
/// sides on one device.
class RemoteInputExampleApp extends StatefulWidget {
  /// Creates the app.
  const RemoteInputExampleApp({super.key});

  @override
  State<RemoteInputExampleApp> createState() => _RemoteInputExampleAppState();
}

class _RemoteInputExampleAppState extends State<RemoteInputExampleApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Whatever happens to the app, control stops with it
    // (docs/design.md §6.2).
    _lifecycle = AppLifecycleListener(
      onDetach: RemoteInputHost.stopAll,
      onExitRequested: () async {
        RemoteInputHost.stopAll();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2C6BED);
    return MaterialApp(
      title: 'remote_input example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}
