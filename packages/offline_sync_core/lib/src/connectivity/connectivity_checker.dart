/// Abstraction over "does the device currently have a network path" and
/// "notify me when that changes".
///
/// Mirrors [LocalStorage]/[SyncTransport]: `core` depends only on this
/// interface, never directly on `connectivity_plus` APIs — so it's
/// fakeable in tests without touching platform channels.
abstract class ConnectivityChecker {
  /// Checked once at startup, so a device that's already online when the
  /// app launches gets an immediate sync attempt instead of waiting for
  /// a connectivity *change* event that will never fire (nothing changed
  /// since the app started).
  Future<bool> hasConnection();

  /// Fires whenever connectivity changes. Implementations should not
  /// emit consecutive duplicate values (`OfflineSync` doesn't re-filter
  /// beyond relying on that).
  Stream<bool> get onConnectivityChanged;
}