// The example's capture: the package's RemoteInputCapture over the remote
// view and RemoteKeyBar for touch devices, sharing one
// RemoteInputCaptureController per viewer so the key bar's keyboard button
// and sticky modifiers reach the capture.
import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

export 'package:remote_input/remote_input.dart' show KeyboardMode, TouchMode;

final Expando<RemoteInputCaptureController> _controllers = Expando();

/// The controller shared by [CaptureView] and [KeyBarView] for [viewer].
RemoteInputCaptureController captureControllerFor(RemoteInputViewer viewer) =>
    _controllers[viewer] ??= RemoteInputCaptureController();

/// Captures pointer and keyboard input over [child], the remote view, and
/// sends it through [viewer].
///
/// [child] fills this widget and shows the remote picture fitted by [fit]
/// into it, like a video view; [contentSize] is the picture's size, so the
/// letterbox bars can be left out of the mapping (`docs/design.md` §3.1).
class CaptureView extends StatelessWidget {
  /// Creates a capture view.
  const CaptureView({
    super.key,
    required this.viewer,
    required this.child,
    this.contentSize,
    this.fit = BoxFit.contain,
    this.keyboardMode = KeyboardMode.auto,
    this.touchMode,
    this.focusNode,
    this.autofocus = true,
  });

  /// The viewer to send through.
  final RemoteInputViewer viewer;

  /// The remote view.
  final Widget child;

  /// The remote picture's size, or `null` for the host's announced size.
  final Size? contentSize;

  /// How the picture fits the view.
  final BoxFit fit;

  /// How keys are sent.
  final KeyboardMode keyboardMode;

  /// How touch maps to the pointer; `null` picks by device.
  final TouchMode? touchMode;

  /// The capture's focus node, if the caller manages focus.
  final FocusNode? focusNode;

  /// Whether to take keyboard focus at once.
  final bool autofocus;

  @override
  Widget build(BuildContext context) => RemoteInputCapture(
    viewer: viewer,
    controller: captureControllerFor(viewer),
    contentSize: contentSize,
    fit: fit,
    keyboardMode: keyboardMode,
    touchMode: touchMode,
    focusNode: focusNode,
    autofocus: autofocus,
    child: SizedBox.expand(child: child),
  );
}

/// Keys a soft keyboard lacks, for touch devices.
class KeyBarView extends StatelessWidget {
  /// Creates the key bar.
  const KeyBarView({super.key, required this.viewer});

  /// The viewer to send through.
  final RemoteInputViewer viewer;

  @override
  Widget build(BuildContext context) =>
      RemoteKeyBar(viewer: viewer, controller: captureControllerFor(viewer));
}
