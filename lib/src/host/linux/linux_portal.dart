import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException, PlatformException;

import '../../surface.dart';

/// What a ScreenCast source is.
enum PortalSourceType {
  /// A whole monitor.
  monitor(1),

  /// One window.
  window(2);

  const PortalSourceType(this.code);

  /// The portal's bit for it.
  final int code;

  /// The type for portal bit [code], or `null`.
  static PortalSourceType? fromCode(int code) => switch (code) {
    1 => monitor,
    2 => window,
    _ => null,
  };
}

/// How the screen cast shows the pointer.
enum PortalCursorMode {
  /// Not at all.
  hidden(1),

  /// Drawn into the frames.
  embedded(2),

  /// As stream metadata.
  metadata(4);

  const PortalCursorMode(this.code);

  /// The portal's bit for it.
  final int code;
}

/// How [RemoteInputPortal.start] ended.
enum PortalStartStatus {
  /// The session is open, with control allowed.
  ok,

  /// The person cancelled the system's dialog.
  cancelled,

  /// The person shared without allowing remote interaction ("Allow Remote
  /// Interaction" off), so there's nothing to control with. The session
  /// was closed.
  noControl,

  /// A session is already open, or a start is under way.
  busy,

  /// No RemoteDesktop portal (version 2 or later), no session bus, not a
  /// Wayland session, or the plugin was built without libei.
  unsupported,

  /// Something else failed; see [PortalStartResult.message].
  error,
}

/// Why a portal session ended ([RemoteInputPortal.closed]).
enum PortalCloseReason {
  /// The app closed it ([RemoteInputPortal.close]).
  closedByApp,

  /// The portal closed it: the person stopped it from the system's sharing
  /// indicator, or the compositor ended it.
  closed,

  /// The connection to the compositor's input (EIS) went away.
  disconnected,
}

/// A screen-cast stream of a portal session.
final class PortalStream {
  /// Creates a [PortalStream].
  const PortalStream({
    required this.nodeId,
    required this.sourceType,
    required this.displayId,
    this.position,
    this.size,
    this.mappingId,
    this.scale = 1.0,
  });

  /// The PipeWire node to capture, with [PortalStartResult.pipewireFd].
  final int nodeId;

  /// A monitor or a window, or `null` if the portal didn't say.
  final PortalSourceType? sourceType;

  /// Where the monitor is, in the compositor's logical pixels. `null` for
  /// a window: Wayland doesn't say where windows are.
  final Offset? position;

  /// The stream's size in logical pixels. For a window, the largest size
  /// the stream can have; its frames are cropped to the window.
  final Size? size;

  /// The portal's mapping id, which ties the stream to its input region.
  final String? mappingId;

  /// The input region's id for this session, for [surface]; 0 if the
  /// stream has no input region (it can't be controlled).
  final int displayId;

  /// The region's physical scale (a HiDPI monitor's 2.0, say).
  final double scale;

  /// The surface to control this stream: its input region. For a window,
  /// whose region starts at 0, 0 at the window's top-left corner, give the
  /// window's size as it changes with [RemoteInputPortal.updateContentSize].
  SharedSurface get surface => SharedSurface.display(displayId);

  @override
  String toString() =>
      'PortalStream(node $nodeId, ${sourceType?.name}, display $displayId)';
}

/// What [RemoteInputPortal.start] returned.
final class PortalStartResult {
  /// Creates a [PortalStartResult].
  const PortalStartResult({
    required this.status,
    this.message,
    this.streams = const [],
    this.pipewireFd = -1,
  });

  /// How it ended.
  final PortalStartStatus status;

  /// What failed, for [PortalStartStatus.error] and
  /// [PortalStartStatus.unsupported]. Not localized.
  final String? message;

  /// The screen-cast streams the person picked (none without a screen
  /// cast).
  final List<PortalStream> streams;

  /// The PipeWire remote's fd for the screen cast, or -1 without one. The
  /// package keeps it open until the session closes: a capturer dup()s it
  /// and closes its own copy.
  final int pipewireFd;

  /// Whether the session is open with control allowed.
  bool get isOk => status == PortalStartStatus.ok;
}

/// The RemoteDesktop portal session that injection on Wayland goes through
/// (`docs/design.md` §7.5). Linux on Wayland only; elsewhere [start]
/// answers [PortalStartStatus.unsupported].
///
/// **Consent is per portal session.** [start] opens the system's "Remote
/// Desktop" dialog, where the presenter allows remote interaction (and, with
/// `screenCast`, picks what to share: one dialog for both). Nothing is
/// remembered: the next session asks again. While a session is open, GNOME
/// shows its sharing indicator, whose Stop closes it.
///
/// **One session at a time.** The package owns it. With `screenCast`, the
/// app hands [PortalStartResult.pipewireFd] and a stream's
/// [PortalStream.nodeId] to its capturer (which dup()s the fd), and
/// controls the stream through [PortalStream.surface].
///
/// **Revoke.** When the session closes (the presenter's Stop, the
/// compositor, or [close]), a live control session stops with
/// `StopReason.permissionDenied`, and [closed] reports why; the app ends its
/// share then. When the app ends a share made from this session, it calls
/// [close], so the system's indicator goes away.
abstract final class RemoteInputPortal {
  static const MethodChannel _channel = MethodChannel('remote_input');
  static final StreamController<PortalCloseReason> _closed =
      StreamController.broadcast();
  static bool _listening = false;
  static List<PortalStream> _streams = const [];
  static final Map<int, Size> _contentSizes = {};

  /// Each portal session's end, with why.
  static Stream<PortalCloseReason> get closed {
    _listen();
    return _closed.stream;
  }

  /// The open session's streams; empty without one.
  static List<PortalStream> get streams => _streams;

  /// Opens a portal session: shows the system's dialog and waits for the
  /// person's answer. With [screenCast], the dialog also asks what to share
  /// ([sourceTypes], [multiple]), and the result carries the streams and
  /// the PipeWire fd.
  static Future<PortalStartResult> start({
    bool screenCast = false,
    Set<PortalSourceType> sourceTypes = const {PortalSourceType.monitor},
    bool multiple = false,
    PortalCursorMode cursorMode = PortalCursorMode.embedded,
  }) async {
    _listen();
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('portalStart', {
        'screenCast': screenCast,
        'sourceTypes': sourceTypes.fold<int>(0, (m, t) => m | t.code),
        'multiple': multiple,
        'cursorMode': cursorMode.code,
      });
    } on MissingPluginException {
      return const PortalStartResult(status: PortalStartStatus.unsupported);
    } on PlatformException catch (e) {
      return PortalStartResult(
        status: PortalStartStatus.error,
        message: e.message,
      );
    }
    final result = parseStartResult(raw ?? const {});
    if (result.isOk) {
      _streams = result.streams;
      _contentSizes.clear();
    }
    return result;
  }

  /// Closes the open session, if any. Its end is reported on [closed] with
  /// [PortalCloseReason.closedByApp].
  static Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('portalClose');
    } on MissingPluginException {
      // Nothing is open where there's no plugin.
    }
  }

  /// The size of window stream [displayId]'s content: the window's size,
  /// as its capturer sees the frames (cropped to the window). The surface's
  /// bounds are then (0, 0) to that size. Until it's given, the stream's
  /// largest size is used, so clicks may land outside a smaller window.
  static void updateContentSize(int displayId, Size size) {
    _contentSizes[displayId] = size;
  }

  /// The content size given for [displayId], if any.
  static Size? contentSizeOf(int displayId) => _contentSizes[displayId];

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_onCall);
  }

  static Future<void> _onCall(MethodCall call) async {
    if (call.method != 'portalClosed') return;
    final args = call.arguments;
    final reason = args is Map ? args['reason'] : null;
    onClosed(switch (reason) {
      'closedByApp' => PortalCloseReason.closedByApp,
      'disconnected' => PortalCloseReason.disconnected,
      _ => PortalCloseReason.closed,
    });
  }

  /// Reports a session's end, as the plugin does. Public for tests.
  @visibleForTesting
  static void onClosed(PortalCloseReason reason) {
    _streams = const [];
    _contentSizes.clear();
    _closed.add(reason);
  }

  /// The result map from the plugin, as a [PortalStartResult].
  @visibleForTesting
  static PortalStartResult parseStartResult(Map<Object?, Object?> raw) {
    final status = PortalStartStatus.values.firstWhere(
      (s) => s.name == raw['status'],
      orElse: () => PortalStartStatus.error,
    );
    final streams = <PortalStream>[];
    final list = raw['streams'];
    if (list is List) {
      for (final s in list) {
        if (s is! Map) continue;
        int? i(String k) => s[k] is int ? s[k] as int : null;
        final x = i('x'), y = i('y'), w = i('width'), h = i('height');
        final type = i('sourceType');
        streams.add(
          PortalStream(
            nodeId: i('nodeId') ?? 0,
            sourceType: type == null ? null : PortalSourceType.fromCode(type),
            displayId: i('displayId') ?? 0,
            position: x != null && y != null
                ? Offset(x.toDouble(), y.toDouble())
                : null,
            size: w != null && h != null
                ? Size(w.toDouble(), h.toDouble())
                : null,
            mappingId: s['mappingId'] is String
                ? s['mappingId'] as String
                : null,
            scale: s['scale'] is double ? s['scale'] as double : 1.0,
          ),
        );
      }
    }
    return PortalStartResult(
      status: status,
      message: raw['message'] is String ? raw['message'] as String : null,
      streams: List.unmodifiable(streams),
      pipewireFd: raw['pipewireFd'] is int ? raw['pipewireFd'] as int : -1,
    );
  }
}
