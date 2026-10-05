/// Test helpers for `remote_input`: an in-memory link and fakes for the
/// host's platform services, so apps can test their consent flow, banner
/// and adapter without injecting anything (`docs/design.md` §7.1).
///
/// ```dart
/// final pair = MemoryInputLink.pair(loss: 0.05, reorder: true);
/// final platform = FakeHostPlatform();
/// final session = RemoteInputHost(platform: platform).enable(
///   link: pair.host,
///   surface: SharedSurface.display(1),
/// );
/// final viewer = RemoteInputViewer(link: pair.viewer);
/// // ... then read platform.injector.events.
/// ```
library;

export 'src/testing/fakes.dart'
    show
        FakeHostPlatform,
        FakeLocalActivity,
        FakeSecureContext,
        FakeSurfaceResolver,
        InjectedButton,
        InjectedEvent,
        InjectedKey,
        InjectedMove,
        InjectedText,
        InjectedWheel,
        RecordingInjector;
export 'src/testing/memory_link.dart' show MemoryInputChannel, MemoryInputLink;
