import 'package:workmanager/workmanager.dart';

/// Task/unique names used to register and identify the periodic
/// background sync job with WorkManager.
const String kOfflineSyncTaskName = 'offline_sync.background_sync';
const String kOfflineSyncUniqueName = 'offline_sync.periodic_task';

/// Schedules `offline_sync`'s queue to be drained periodically, even
/// while the app is closed.
///
/// This is a thin scheduling wrapper around `workmanager`. It does NOT
/// run the sync itself — see [runBackgroundSyncTask] for that — because
/// the actual work happens in a separate isolate that has no access to
/// this class or to your running app's `OfflineSync` instance.
class BackgroundSync {
  BackgroundSync._();

  /// Call once from `main()`, **before** `runApp()`.
  ///
  /// [callbackDispatcher] must be a top-level or `static` function
  /// annotated with `@pragma('vm:entry-point')` — WorkManager spawns a
  /// fresh, isolated Dart isolate to invoke it in when a background task
  /// fires, so it cannot be a closure or reference anything from your
  /// widget tree.
  ///
  /// [frequency] is a *minimum* interval, not a guarantee — the OS
  /// decides real execution timing based on battery, network, and (on
  /// iOS especially) how recently the app was used. Android additionally
  /// enforces a hard floor of 15 minutes for periodic work; anything
  /// shorter is silently clamped by the OS.
  static Future<void> initialize({
    required Function callbackDispatcher,
    Duration frequency = const Duration(minutes: 15),
    Constraints? constraints,
  }) async {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      kOfflineSyncUniqueName,
      kOfflineSyncTaskName,
      frequency: frequency,
      constraints:
          constraints ?? Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }

  /// Stops the periodic background sync task.
  static Future<void> cancel() =>
      Workmanager().cancelByUniqueName(kOfflineSyncUniqueName);
}

/// The actual routing/error-mapping logic behind [runBackgroundSyncTask],
/// pulled out into a pure function so it's unit-testable without needing
/// the real `workmanager` plugin or a platform channel.
///
/// Returns `true` if WorkManager should consider this run successful
/// (including "not our task, ignored"), `false` to ask WorkManager to
/// retry per its own native backoff — a *different* mechanism from
/// `RetryPolicy` (Phase 3), which only governs retries *within* one
/// `sync()` pass, not whole task retries.
Future<bool> handleBackgroundTask(
  String task,
  Future<void> Function() performSync,
) async {
  if (task != kOfflineSyncTaskName) {
    // Not ours — some other WorkManager task sharing this dispatcher.
    return true;
  }
  try {
    await performSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Call this from inside your own `@pragma('vm:entry-point')` top-level
/// callback dispatcher, wrapping `Workmanager().executeTask`.
///
/// [performSync] is *your* app code — it must fully rebuild whatever
/// `OfflineSync.initialize()` needs from scratch (the same [LocalStorage]
/// pointing at the same on-disk database, the same [SyncTransport], the
/// same registered adapters) and then call `OfflineSync.sync()`. This
/// can't be handled generically inside `offline_sync_core`, because only
/// your app knows its adapters/endpoints/auth — and it has to happen
/// again here because this isolate shares no memory with whatever your
/// main isolate already set up.
///
/// ```dart
/// @pragma('vm:entry-point')
/// void callbackDispatcher() {
///   runBackgroundSyncTask(() async {
///     await OfflineSync.initialize(
///       storage: DriftLocalStorage(), // same on-disk file as the app
///       transport: DioSyncTransport(Dio(BaseOptions(baseUrl: kApiBaseUrl))),
///       autoSync: false, // no widget tree here to trigger from anyway
///     );
///     OfflineSync.register<Todo>(todoAdapter);
///     await OfflineSync.sync();
///   });
/// }
/// ```
void runBackgroundSyncTask(Future<void> Function() performSync) {
  Workmanager().executeTask(
    (task, inputData) => handleBackgroundTask(task, performSync),
  );
}