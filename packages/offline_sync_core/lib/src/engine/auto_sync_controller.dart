import 'dart:async';

import '../connectivity/connectivity_checker.dart';

/// Starts/stops listening for connectivity changes and invokes a
/// callback whenever the device comes back online — including once at
/// startup if it's already online (a connectivity *change* event never
/// fires for a state that hasn't changed since launch).
class AutoSyncController {
  AutoSyncController(this._checker);

  final ConnectivityChecker _checker;
  StreamSubscription<bool>? _subscription;

  Future<void> start(Future<void> Function() onConnectivityRestored) async {
    await stop();

    if (await _checker.hasConnection()) {
      unawaited(onConnectivityRestored());
    }

    _subscription = _checker.onConnectivityChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(onConnectivityRestored());
      }
    });
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}