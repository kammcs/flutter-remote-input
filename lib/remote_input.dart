/// Remote keyboard and mouse control for Flutter apps.
///
/// A **viewer** on any platform sends pointer and keyboard input over a
/// link the app provides ([RemoteInputViewer]), captured over the remote
/// view by [RemoteInputCapture] (with a [RemoteKeyBar] for phones); the
/// **host** on Windows or macOS replays it as local input
/// ([RemoteInputHost], [ControlSession]), with safety controls: off by
/// default, instant stop, local input wins.
///
/// **Pre-release.** The protocol, the Dart core (roadmap M1) and the
/// capture widget (M4) are built; the Windows and macOS injectors are not
/// yet, so [RemoteInputHost.isSupported] is false everywhere. The design is in
/// `docs/design.md`: <https://github.com/kammcs/flutter-remote-input>.
library;

export 'src/host/host.dart' show RemoteInputHost;
export 'src/host/host_types.dart'
    show DropReason, KeyPress, SessionStats, ViolationKind;
export 'src/host/options.dart'
    show HostOptions, InputLimits, KeyFilter, ModifierMapping, ResumePolicy;
export 'src/host/platform.dart'
    show
        HostPlatform,
        HostUnavailableException,
        HostUnavailableReason,
        InjectResult,
        InputInjector,
        InputKind,
        LocalActivityMonitor,
        SecureContextProbe,
        SurfaceResolver;
export 'src/host/session.dart' show ControlSession;
export 'src/keys.dart' show HidModifier;
export 'src/link.dart' show InputChannel, InputLink;
export 'src/protocol/wire_types.dart'
    show
        BlockReason,
        KeyAction,
        KeyModifiers,
        PauseReason,
        PeerPlatform,
        PointerButton,
        StopReason,
        WheelUnit,
        remoteInputProtocolVersion;
export 'src/session_state.dart'
    show
        SessionActive,
        SessionBlocked,
        SessionPaused,
        SessionState,
        SessionStopped,
        SessionWaiting;
export 'src/surface.dart'
    show
        DisplayInfo,
        DisplaySurface,
        RectSurface,
        SharedSurface,
        SurfaceGeometry,
        WindowSurface;
export 'src/viewer/capture/capture.dart'
    show
        RemoteInputCapture,
        RemoteInputCaptureController,
        RemoteKeyBar,
        StickyModifierState,
        TouchMode;
export 'src/viewer/capture/key_routing.dart' show KeyboardMode;
export 'src/viewer/viewer.dart'
    show RemoteInputViewer, RemoteSurface, ViewerOptions, ViewerStats;
