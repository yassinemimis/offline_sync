import 'package:workmanager/workmanager.dart';

import 'background_sync_log.dart';
import 'background_task_handler.dart';

export 'background_sync_log.dart' show BackgroundSyncAttempt, BackgroundSyncLog;
export 'background_task_handler.dart'
    show kOfflineSyncTaskName, kOfflineSyncUniqueName, handleBackgroundTask;

/// Schedules `offline_sync`'s queue to be drained periodically, even
/// while the app is closed.
class BackgroundSync {
  BackgroundSync._();

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

  static Future<void> cancel() =>
      Workmanager().cancelByUniqueName(kOfflineSyncUniqueName);

  /// For manual/on-demand testing — see the package README. Prefer a
  /// fresh, timestamped `uniqueName` per call so repeated test runs don't
  /// get silently ignored by `ExistingWorkPolicy.keep`.
  static Future<void> scheduleOneOffTest({
    Constraints? constraints,
  }) {
    return Workmanager().registerOneOffTask(
      'offline_sync.manual_test_${DateTime.now().millisecondsSinceEpoch}',
      kOfflineSyncTaskName,
      constraints:
          constraints ?? Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  /// Diagnostics — what actually happened on the last N background runs.
  /// Safe to call from your UI at any time.
  static Future<List<BackgroundSyncAttempt>> recentAttempts() =>
      BackgroundSyncLog.recentAttempts();
}

void runBackgroundSyncTask(Future<void> Function() performSync) {
  Workmanager().executeTask(
    (task, inputData) => handleBackgroundTask(task, performSync),
  );
}