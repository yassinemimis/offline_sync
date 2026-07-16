import 'package:connectivity_plus/connectivity_plus.dart';

import './connectivity_checker.dart';

/// Default [ConnectivityChecker], backed by `connectivity_plus`.
///
/// "Connected" here means the OS reports at least one active network
/// interface (wifi, mobile data, ethernet...) — **not** that the
/// interface actually has working internet. A device on a wifi network
/// with no real internet access still reports "connected". That's fine:
/// `sync()` will simply fail against the real server (and retry per
/// [RetryPolicy]) — this checker's only job is "is it worth trying at
/// all right now", not "will it definitely work".
class ConnectivityPlusChecker implements ConnectivityChecker {
  const ConnectivityPlusChecker();

  static bool _isConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> hasConnection() async {
    final results = await Connectivity().checkConnectivity();
    return _isConnected(results);
  }

  @override
  Stream<bool> get onConnectivityChanged =>
      Connectivity().onConnectivityChanged.map(_isConnected).distinct();
}