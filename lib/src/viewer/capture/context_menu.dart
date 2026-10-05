/// Turns the browser's context menu off while any capture needs right
/// clicks for the host, without the captures fighting over it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A process-wide count of the captures that want the browser's context
/// menu off (`docs/design.md` §8).
///
/// On the web, a right click over the remote view would open the browser's
/// context menu as well as reaching the host. While at least one capture is
/// active the menu is turned off ([BrowserContextMenu.disableContextMenu]),
/// and it's turned back on when the last one lets go. If the app had turned
/// it off itself before the first capture asked, it's left alone both ways.
/// Elsewhere this does nothing.
abstract final class CaptureContextMenu {
  static int _holders = 0;
  static bool _turnedOff = false;
  static bool _enabling = false;

  /// Whether the browser's context menu applies: the web. Tests turn it on.
  @visibleForTesting
  static bool applies = kIsWeb;

  /// Turns the menu off. Tests replace it.
  @visibleForTesting
  static Future<void> Function() disable =
      BrowserContextMenu.disableContextMenu;

  /// Turns the menu on. Tests replace it.
  @visibleForTesting
  static Future<void> Function() enable = BrowserContextMenu.enableContextMenu;

  /// Whether the browser's context menu applies and is in the default
  /// enabled state, before any capture changed it. Tests replace it.
  @visibleForTesting
  static bool Function() menuEnabled = () => BrowserContextMenu.enabled;

  /// How many captures want the menu off now.
  static int get holders => _holders;

  /// A capture wants the menu off.
  static void acquire() {
    if (!applies) return;
    _holders++;
    if (_holders != 1) return;
    // Off, and not because a release of ours is still turning it on: the
    // app turned it off. Leave it.
    if (!_enabling && !menuEnabled()) return;
    _turnedOff = true;
    unawaited(disable().catchError((Object _) {}));
  }

  /// A capture no longer wants the menu off.
  static void release() {
    if (!applies || _holders == 0) return;
    _holders--;
    if (_holders != 0 || !_turnedOff) return;
    _turnedOff = false;
    _enabling = true;
    unawaited(
      enable().catchError((Object _) {}).whenComplete(() => _enabling = false),
    );
  }
}
