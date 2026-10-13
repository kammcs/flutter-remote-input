// The paste-shortcut KeyFilter preset and the filter combinator (RIN-48,
// docs/design.md §6.4 and §11).
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import 'session_test.dart' show Rig, usageA, usageR;
import 'system_keys_test.dart'
    show alt, combo, ctrl, keyC, keyV, keyX, meta, pressed, shift, stuck, tab;

const insert = 0x00070049;
const paste = 0x0007007D;

bool allows(
  int usage, {
  Set<int> held = const {},
  int modifiers = 0,
  PeerPlatform host = PeerPlatform.windows,
  KeyFilter filter = KeyFilters.noPaste,
}) => filter(
  KeyPress(
    usage: usage,
    heldModifiers: held,
    modifiers: modifiers,
    hostPlatform: host,
  ),
);

Rig _rig(
  FakeAsync async, {
  required PeerPlatform host,
  required PeerPlatform viewer,
  KeyFilter filter = KeyFilters.noPaste,
}) => Rig(
  async,
  platform: FakeHostPlatform(platform: host),
  options: HostOptions(keyFilter: filter),
  viewerPlatform: viewer,
);

void main() {
  tearDown(RemoteInputHost.stopAll);

  group('KeyFilters.noPaste as a function', () {
    test('Windows host: Ctrl+V, Shift+Insert, Win+V and the Paste key', () {
      for (final held in [
        {ctrl},
        {ctrl, shift},
        {ctrl, alt},
        {HidModifier.controlRight},
        {meta},
      ]) {
        expect(allows(keyV, held: held), isFalse, reason: '$held');
      }
      expect(allows(keyV, modifiers: KeyModifiers.control), isFalse);
      expect(allows(insert, held: {shift}), isFalse);
      expect(allows(insert, held: {HidModifier.shiftRight}), isFalse);
      expect(allows(insert, modifiers: KeyModifiers.shift), isFalse);
      expect(allows(paste), isFalse);
      // Copy, cut, plain V and Insert, Shift+V and Ctrl+Insert (copy) pass.
      expect(allows(keyC, held: {ctrl}), isTrue);
      expect(allows(keyX, held: {ctrl}), isTrue);
      expect(allows(keyV), isTrue);
      expect(allows(keyV, held: {shift}), isTrue);
      expect(allows(keyV, held: {alt}), isTrue);
      expect(allows(insert), isTrue);
      expect(allows(insert, held: {ctrl}), isTrue);
    });

    test('Mac host: V with Command, and the Paste key', () {
      const mac = PeerPlatform.macos;
      for (final held in [
        {meta},
        {meta, shift},
        {meta, alt, shift},
        {HidModifier.metaRight},
      ]) {
        expect(
          allows(keyV, held: held, host: mac),
          isFalse,
          reason: '$held',
        );
      }
      expect(allows(keyV, modifiers: KeyModifiers.meta, host: mac), isFalse);
      expect(allows(paste, host: mac), isFalse);
      // Ctrl+V and Shift+Insert aren't paste on a Mac; copy passes.
      expect(allows(keyV, held: {ctrl}, host: mac), isTrue);
      expect(allows(insert, held: {shift}, host: mac), isTrue);
      expect(allows(keyC, held: {meta}, host: mac), isTrue);
      expect(allows(keyV, host: mac), isTrue);
    });

    test('an unknown host gets both lists', () {
      const unknown = PeerPlatform.unknown;
      expect(allows(keyV, held: {ctrl}, host: unknown), isFalse);
      expect(allows(keyV, held: {meta}, host: unknown), isFalse);
      expect(allows(insert, held: {shift}, host: unknown), isFalse);
      expect(allows(keyC, held: {ctrl}, host: unknown), isTrue);
    });
  });

  group('KeyFilters.noPaste in a session', () {
    for (final (host, viewer, mod) in [
      (PeerPlatform.windows, PeerPlatform.windows, ctrl),
      (PeerPlatform.windows, PeerPlatform.macos, meta), // Cmd+V → Ctrl+V
      (PeerPlatform.macos, PeerPlatform.macos, meta),
      (PeerPlatform.macos, PeerPlatform.windows, ctrl), // Ctrl+V → Cmd+V
    ]) {
      test('${viewer.name} viewer, ${host.name} host: paste is dropped, '
          'copy passes, nothing stuck', () {
        fakeAsync((async) {
          final rig = _rig(async, host: host, viewer: viewer);
          combo(rig, [mod], keyV);
          combo(rig, [mod, shift], keyV);
          combo(rig, [mod], keyC);
          final shortcut = host == PeerPlatform.macos ? meta : ctrl;
          expect(pressed(rig.events), [
            shortcut,
            shortcut,
            shift,
            shortcut,
            keyC,
          ]);
          expect(stuck(rig.events), isEmpty);
          // The two presses; their repeats and releases have nothing held.
          expect(rig.dropped(DropReason.filtered), 2);
        });
      });
    }

    test('Shift+Insert on a Windows host, and the Paste key', () {
      fakeAsync((async) {
        final rig = _rig(
          async,
          host: PeerPlatform.windows,
          viewer: PeerPlatform.windows,
        );
        combo(rig, [shift], insert);
        combo(rig, [], paste);
        expect(pressed(rig.events), [shift]);
        expect(stuck(rig.events), isEmpty);
      });
    });

    test('V held, then Control: V is released before it can repeat', () {
      fakeAsync((async) {
        final rig = _rig(
          async,
          host: PeerPlatform.windows,
          viewer: PeerPlatform.windows,
        );
        rig.viewer
          ..key(keyV, KeyAction.down)
          ..key(ctrl, KeyAction.down, modifiers: KeyModifiers.control)
          ..key(keyV, KeyAction.repeat, modifiers: KeyModifiers.control);
        rig.flush();
        expect(rig.events, const [
          InjectedKey(keyV, down: true),
          InjectedKey(ctrl, down: true),
          InjectedKey(keyV, down: false),
        ]);
      });
    });
  });

  group('KeyFilters.all', () {
    test('passes only what every filter passes', () {
      final both = KeyFilters.all([KeyFilters.windowShare, KeyFilters.noPaste]);
      expect(allows(keyV, held: {ctrl}, filter: both), isFalse); // paste
      expect(allows(usageR, held: {meta}, filter: both), isFalse); // Win+R
      expect(allows(tab, held: {alt}, filter: both), isFalse); // Alt+Tab
      expect(allows(keyC, held: {ctrl}, filter: both), isTrue);
      expect(allows(usageA, filter: both), isTrue);
    });

    test('an empty list passes everything; the list is copied', () {
      final filters = <KeyFilter>[];
      final none = KeyFilters.all(filters);
      filters.add((_) => false);
      expect(allows(keyV, held: {ctrl}, filter: none), isTrue);
    });

    test('stops at the first filter that drops the press', () {
      final calls = <int>[];
      final filter = KeyFilters.all([
        (p) {
          calls.add(1);
          return p.usage != usageA;
        },
        (p) {
          calls.add(2);
          return true;
        },
      ]);
      expect(allows(usageA, filter: filter), isFalse);
      expect(calls, [1]);
      expect(allows(keyC, filter: filter), isTrue);
      expect(calls, [1, 1, 2]);
    });

    test('in a session, with the window-share preset', () {
      fakeAsync((async) {
        final rig = _rig(
          async,
          host: PeerPlatform.windows,
          viewer: PeerPlatform.windows,
          filter: KeyFilters.all([KeyFilters.windowShare, KeyFilters.noPaste]),
        );
        combo(rig, [ctrl], keyV);
        combo(rig, [meta], usageR);
        combo(rig, [ctrl], keyC);
        expect(pressed(rig.events), [ctrl, ctrl, keyC]);
        expect(stuck(rig.events), isEmpty);
      });
    });
  });
}
