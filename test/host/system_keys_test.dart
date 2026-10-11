// System keys dropped by default, and the window-share KeyFilter preset
// (RIN-43, docs/design.md §6.4).
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import 'session_test.dart' show Rig, usageA, usageR;

// Usages, as Flutter's PhysicalKeyboardKey.usbHidUsage reports them.
const sleep = 0x00010082;
const wakeUp = 0x00010083;
const power = 0x00070066;
const launchApp1 = 0x000C0194;
const launchApp2 = 0x000C0192;
const launchMail = 0x000C018A;
const browserHome = 0x000C0223;
const mediaPlayPause = 0x000C00CD;
const eject = 0x000C00B8;
const fn = 0x00000012;

const keyC = 0x00070006;
const keyH = 0x0007000B;
const keyL = 0x0007000F;
const keyQ = 0x00070014;
const keyV = 0x00070019;
const keyX = 0x0007001B;
const keyZ = 0x0007001D;
const digit1 = 0x0007001E;
const enter = 0x00070028;
const escape = 0x00070029;
const tab = 0x0007002B;
const space = 0x0007002C;
const f3 = 0x0007003C;
const f4 = 0x0007003D;
const f5 = 0x0007003E;
const arrowLeft = 0x00070050;
const arrowUp = 0x00070052;
const volumeUp = 0x00070080;

const ctrl = HidModifier.controlLeft;
const shift = HidModifier.shiftLeft;
const alt = HidModifier.altLeft;
const meta = HidModifier.metaLeft;

/// Presses [modifiers] in order, then [key] (with a repeat), then lets go
/// of everything in reverse, as a viewer does, with the modifier bits a
/// viewer reports at each step.
void combo(Rig rig, List<int> modifiers, int key, {bool repeat = true}) {
  var bits = 0;
  for (final m in modifiers) {
    bits |= HidModifier.bitOf(m);
    rig.viewer.key(m, KeyAction.down, modifiers: bits);
  }
  rig.viewer.key(key, KeyAction.down, modifiers: bits);
  if (repeat) rig.viewer.key(key, KeyAction.repeat, modifiers: bits);
  rig.viewer.key(key, KeyAction.up, modifiers: bits);
  for (final m in modifiers.reversed) {
    bits &= ~HidModifier.bitOf(m);
    rig.viewer.key(m, KeyAction.up, modifiers: bits);
  }
  rig.flush();
}

/// The usages pressed and not released in [events]: stuck keys.
Set<int> stuck(List<InjectedEvent> events) {
  final down = <int>{};
  for (final e in events.whereType<InjectedKey>()) {
    if (e.down) {
      down.add(e.usage);
    } else {
      down.remove(e.usage);
    }
  }
  return down;
}

/// The usages pressed (not repeats) in [events].
List<int> pressed(List<InjectedEvent> events) => [
  for (final e in events.whereType<InjectedKey>())
    if (e.down && !e.repeat) e.usage,
];

Rig windowsHost(
  FakeAsync async, {
  PeerPlatform viewer = PeerPlatform.windows,
}) => Rig(
  async,
  options: const HostOptions(keyFilter: KeyFilters.windowShare),
  viewerPlatform: viewer,
);

Rig macHost(FakeAsync async, {PeerPlatform viewer = PeerPlatform.macos}) => Rig(
  async,
  platform: FakeHostPlatform(platform: PeerPlatform.macos),
  options: const HostOptions(keyFilter: KeyFilters.windowShare),
  viewerPlatform: viewer,
);

void main() {
  tearDown(RemoteInputHost.stopAll);

  group('system keys (default)', () {
    const systemKeys = [
      sleep,
      wakeUp,
      power,
      launchApp1,
      launchApp2,
      launchMail,
      browserHome,
      mediaPlayPause,
      eject,
      fn,
    ];

    test('isSystemKey: pages 0x00, 0x01 and 0x0C, and Power', () {
      for (final k in systemKeys) {
        expect(KeyFilters.isSystemKey(k), isTrue, reason: k.toRadixString(16));
      }
      for (final k in [usageA, escape, tab, f5, volumeUp, ctrl, meta]) {
        expect(KeyFilters.isSystemKey(k), isFalse, reason: k.toRadixString(16));
      }
    });

    for (final host in [PeerPlatform.windows, PeerPlatform.macos]) {
      test('are dropped and counted on ${host.name}, down, repeat and up', () {
        fakeAsync((async) {
          final filtered = <int>[];
          final rig = Rig(
            async,
            platform: FakeHostPlatform(platform: host),
            viewerPlatform: host,
            options: HostOptions(
              keyFilter: (p) {
                filtered.add(p.usage);
                return true;
              },
            ),
          );
          for (final k in systemKeys) {
            rig.viewer
              ..key(k, KeyAction.down)
              ..key(k, KeyAction.repeat)
              ..key(k, KeyAction.up);
          }
          rig.viewer
            ..key(usageA, KeyAction.down)
            ..key(usageA, KeyAction.up);
          rig.flush();
          expect(rig.events, const [
            InjectedKey(usageA, down: true),
            InjectedKey(usageA, down: false),
          ]);
          expect(rig.dropped(DropReason.systemKey), systemKeys.length * 3);
          expect(rig.session.stats.totalDropped, systemKeys.length * 3);
          // The app's filter never sees them.
          expect(filtered, [usageA]);
        });
      });
    }

    test('a dropped system key held with a modifier leaves nothing stuck', () {
      fakeAsync((async) {
        final rig = Rig(async);
        combo(rig, [ctrl, alt], power);
        combo(rig, [meta], launchApp1);
        expect(pressed(rig.events), [ctrl, alt, meta]);
        expect(stuck(rig.events), isEmpty);
        expect(rig.dropped(DropReason.systemKey), 6);
      });
    });

    test('allowSystemKeys lets them through', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: const HostOptions(allowSystemKeys: true),
        );
        for (final k in systemKeys) {
          rig.viewer
            ..key(k, KeyAction.down)
            ..key(k, KeyAction.up);
        }
        rig.flush();
        expect(pressed(rig.events), systemKeys);
        expect(stuck(rig.events), isEmpty);
        expect(rig.dropped(DropReason.systemKey), 0);
      });
    });
  });

  group('KeyFilters.windowShare on a Windows host', () {
    test('drops the Windows key and every Win combination', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        for (final k in [usageR, keyL, keyH, 0x00070004, digit1, tab, keyX]) {
          combo(rig, [meta], k);
        }
        combo(rig, [HidModifier.metaRight], usageR);
        combo(rig, [ctrl, meta], arrowLeft);
        expect(pressed(rig.events), [ctrl]);
        expect(stuck(rig.events), isEmpty);
        // The Win key and each key's press, 8 times; Ctrl+Win+Left's Win
        // and Left. Their repeats and releases have nothing held.
        expect(rig.dropped(DropReason.filtered), 8 + 8 + 2);
        expect(rig.dropped(DropReason.notHeld), 9 * 3);
      });
    });

    test('drops Ctrl+Shift+Esc and Ctrl+Esc, with their repeats', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        combo(rig, [ctrl, shift], escape);
        combo(rig, [ctrl], escape);
        expect(pressed(rig.events), [ctrl, shift, ctrl]);
        expect(stuck(rig.events), isEmpty);
        expect(rig.dropped(DropReason.filtered), 2);
      });
    });

    test('drops Alt+Tab, Alt+Shift+Tab, Ctrl+Alt+Tab and Alt+Esc', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        combo(rig, [alt], tab);
        combo(rig, [alt, shift], tab);
        combo(rig, [ctrl, alt], tab);
        combo(rig, [alt], escape);
        expect(pressed(rig.events), [alt, alt, shift, ctrl, alt, alt]);
        expect(stuck(rig.events), isEmpty);
        expect(rig.dropped(DropReason.filtered), 4);
      });
    });

    test('lets ordinary typing and Ctrl shortcuts through', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        for (final k in [usageA, keyC, keyV, keyX, keyZ]) {
          combo(rig, [ctrl], k);
        }
        combo(rig, [shift], usageA);
        combo(rig, [alt], f4); // closes the shared window: its own business
        combo(rig, [ctrl], tab); // the app's tabs
        for (final k in [usageA, escape, tab, enter, arrowLeft, f5]) {
          combo(rig, [], k);
        }
        rig.viewer.text('héllo');
        rig.flush();
        expect(rig.dropped(DropReason.filtered), 0);
        expect(pressed(rig.events), [
          for (final k in [usageA, keyC, keyV, keyX, keyZ]) ...[ctrl, k],
          shift,
          usageA,
          alt,
          f4,
          ctrl,
          tab,
          usageA,
          escape,
          tab,
          enter,
          arrowLeft,
          f5,
        ]);
        expect(rig.events.whereType<InjectedText>().single.text, 'héllo');
        expect(stuck(rig.events), isEmpty);
      });
    });

    test('Win held, then R: R dropped, nothing stuck', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        rig.viewer
          ..key(meta, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.repeat, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.up, modifiers: KeyModifiers.meta)
          ..key(meta, KeyAction.up);
        rig.flush();
        expect(rig.events, isEmpty);
        expect(rig.dropped(DropReason.filtered), 2);
        expect(
          rig.dropped(DropReason.notHeld),
          3,
        ); // R's repeat and release, Win's release
      });
    });

    test('R held, then Win: Win dropped, R released as typed', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        rig.viewer
          ..key(usageR, KeyAction.down)
          ..key(meta, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.repeat, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.up, modifiers: KeyModifiers.meta)
          ..key(meta, KeyAction.up);
        rig.flush();
        expect(rig.events, const [
          InjectedKey(usageR, down: true),
          InjectedKey(usageR, down: false),
        ]);
      });
    });

    test('Esc held, then Ctrl: Esc is released', () {
      fakeAsync((async) {
        final rig = windowsHost(async);
        rig.viewer
          ..key(escape, KeyAction.down)
          ..key(ctrl, KeyAction.down, modifiers: KeyModifiers.control)
          ..key(escape, KeyAction.repeat, modifiers: KeyModifiers.control)
          ..key(escape, KeyAction.up, modifiers: KeyModifiers.control)
          ..key(ctrl, KeyAction.up);
        rig.flush();
        expect(rig.events, const [
          InjectedKey(escape, down: true),
          InjectedKey(ctrl, down: true),
          InjectedKey(escape, down: false),
          InjectedKey(ctrl, down: false),
        ]);
      });
    });

    test("from a Mac viewer: Cmd+C works, Ctrl (the host's Win) doesn't", () {
      fakeAsync((async) {
        final rig = windowsHost(async, viewer: PeerPlatform.macos);
        combo(rig, [meta], keyC); // Cmd+C arrives as Ctrl+C
        combo(rig, [ctrl], usageR); // Ctrl+R arrives as Win+R
        expect(pressed(rig.events), [ctrl, keyC]);
        expect(stuck(rig.events), isEmpty);
      });
    });
  });

  group('KeyFilters.windowShare on a Mac host', () {
    test('drops the app switcher, Spotlight, Force Quit, lock and log out', () {
      fakeAsync((async) {
        final rig = macHost(async);
        combo(rig, [meta], tab);
        combo(rig, [meta, shift], tab);
        combo(rig, [meta], space);
        combo(rig, [meta, alt], space);
        combo(rig, [ctrl, meta], space);
        combo(rig, [meta, alt], escape);
        combo(rig, [ctrl, meta], keyQ);
        combo(rig, [meta, shift], keyQ);
        combo(rig, [meta, alt, shift], keyQ);
        expect(
          rig.events.whereType<InjectedKey>().where(
            (e) => !HidModifier.isModifier(e.usage),
          ),
          isEmpty,
        );
        expect(stuck(rig.events), isEmpty);
        expect(rig.dropped(DropReason.filtered), 9);
      });
    });

    test('drops Mission Control, Spaces, and menu bar, Dock and VoiceOver '
        'focus keys', () {
      fakeAsync((async) {
        final rig = macHost(async);
        combo(rig, [ctrl], arrowLeft);
        combo(rig, [ctrl], arrowUp);
        combo(rig, [ctrl], f3);
        combo(rig, [meta], f5);
        expect(
          rig.events.whereType<InjectedKey>().where(
            (e) => !HidModifier.isModifier(e.usage),
          ),
          isEmpty,
        );
        expect(stuck(rig.events), isEmpty);
      });
    });

    test('lets ordinary typing and Cmd shortcuts through', () {
      fakeAsync((async) {
        final rig = macHost(async);
        for (final k in [usageA, keyC, keyV, keyX, keyZ, keyQ, arrowLeft]) {
          combo(rig, [meta], k);
        }
        combo(rig, [meta, shift], keyZ); // redo
        combo(rig, [alt], arrowLeft); // word left
        combo(rig, [ctrl, alt], arrowLeft);
        combo(rig, [shift], usageA);
        combo(rig, [ctrl], usageA); // line start, in text fields
        for (final k in [usageA, escape, tab, space, enter, f5]) {
          combo(rig, [], k);
        }
        expect(rig.dropped(DropReason.filtered), 0);
        expect(pressed(rig.events), [
          for (final k in [
            usageA,
            keyC,
            keyV,
            keyX,
            keyZ,
            keyQ,
            arrowLeft,
          ]) ...[meta, k],
          meta,
          shift,
          keyZ,
          alt,
          arrowLeft,
          ctrl,
          alt,
          arrowLeft,
          shift,
          usageA,
          ctrl,
          usageA,
          usageA,
          escape,
          tab,
          space,
          enter,
          f5,
        ]);
        expect(stuck(rig.events), isEmpty);
      });
    });

    test("from a Windows viewer: Ctrl+C, V, X, Z and A arrive as Cmd and "
        "work; Ctrl+Tab becomes Cmd+Tab and is dropped", () {
      fakeAsync((async) {
        final rig = macHost(async, viewer: PeerPlatform.windows);
        for (final k in [usageA, keyC, keyV, keyX, keyZ]) {
          combo(rig, [ctrl], k);
        }
        combo(rig, [ctrl], tab);
        expect(pressed(rig.events), [
          for (final k in [usageA, keyC, keyV, keyX, keyZ]) ...[meta, k],
          meta,
        ]);
        expect(rig.dropped(DropReason.filtered), 1);
        expect(stuck(rig.events), isEmpty);
      });
    });

    test('Cmd held, then Tab: Tab dropped, Cmd released cleanly', () {
      fakeAsync((async) {
        final rig = macHost(async);
        rig.viewer
          ..key(meta, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(tab, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(tab, KeyAction.repeat, modifiers: KeyModifiers.meta)
          ..key(tab, KeyAction.up, modifiers: KeyModifiers.meta)
          ..key(meta, KeyAction.up);
        rig.flush();
        expect(rig.events, const [
          InjectedKey(meta, down: true),
          InjectedKey(meta, down: false),
        ]);
      });
    });

    test('Tab held, then Cmd: Tab is released', () {
      fakeAsync((async) {
        final rig = macHost(async);
        rig.viewer
          ..key(tab, KeyAction.down)
          ..key(meta, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(tab, KeyAction.repeat, modifiers: KeyModifiers.meta)
          ..key(tab, KeyAction.up, modifiers: KeyModifiers.meta)
          ..key(meta, KeyAction.up);
        rig.flush();
        expect(rig.events, const [
          InjectedKey(tab, down: true),
          InjectedKey(meta, down: true),
          InjectedKey(tab, down: false),
          InjectedKey(meta, down: false),
        ]);
      });
    });
  });

  group('KeyFilters.windowShare as a function', () {
    bool allows(
      int usage, {
      Set<int> held = const {},
      int modifiers = 0,
      PeerPlatform host = PeerPlatform.windows,
    }) => KeyFilters.windowShare(
      KeyPress(
        usage: usage,
        heldModifiers: held,
        modifiers: modifiers,
        hostPlatform: host,
      ),
    );

    test('reads both the held modifiers and the viewer-reported ones', () {
      expect(allows(usageR, held: {meta}), isFalse);
      expect(allows(usageR, modifiers: KeyModifiers.meta), isFalse);
      expect(allows(usageR), isTrue);
      expect(allows(tab, held: {meta}, host: PeerPlatform.macos), isFalse);
      expect(
        allows(tab, modifiers: KeyModifiers.meta, host: PeerPlatform.macos),
        isFalse,
      );
    });

    test('an unknown host gets both lists', () {
      const unknown = PeerPlatform.unknown;
      expect(allows(meta, host: unknown), isFalse);
      expect(allows(space, held: {meta}, host: unknown), isFalse);
      expect(allows(arrowLeft, held: {ctrl}, host: unknown), isFalse);
      expect(allows(keyC, held: {ctrl}, host: unknown), isTrue);
    });

    test('drops system keys even when the session allows them', () {
      expect(allows(sleep), isFalse);
      expect(allows(fn, host: PeerPlatform.macos), isFalse);
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: const HostOptions(
            allowSystemKeys: true,
            keyFilter: KeyFilters.windowShare,
          ),
        );
        combo(rig, [], launchApp1, repeat: false);
        expect(rig.events, isEmpty);
        expect(rig.dropped(DropReason.filtered), 1);
      });
    });
  });
}
