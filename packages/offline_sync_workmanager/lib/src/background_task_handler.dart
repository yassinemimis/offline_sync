import 'dart:async';

import 'background_sync_log.dart';

const String kOfflineSyncTaskName = 'offline_sync.background_sync';
const String kOfflineSyncUniqueName = 'offline_sync.periodic_task';

/// How long [performSync] gets before we give up and report a timeout
/// instead of leaving WorkManager waiting indefinitely on a hung request.
const Duration kBackgroundSyncTimeout = Duration(minutes: 2);

/// The routing/timeout/logging logic behind [runBackgroundSyncTask],
/// pulled into a pure function so it's unit-testable without the real
/// `workmanager` plugin.
///
/// Every attempt is automatically recorded via [BackgroundSyncLog] —
/// success, failure (with the error message), or timeout — regardless of
/// what [performSync] itself does. You don't need to add your own
/// logging inside [performSync] just to know whether it ran.
Future<bool> handleBackgroundTask(
  String task,
  Future<void> Function() performSync,
) async {
  if (task != kOfflineSyncTaskName) {
    return true; // not ours — some other WorkManager task, ignore
  }

  final startedAt = DateTime.now();

  try {
    await performSync().timeout(kBackgroundSyncTimeout);
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'success',
    ));
    return true;
  } on TimeoutException {
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'timeout',
      detail: 'exceeded $kBackgroundSyncTimeout',
    ));
    return false; // ask WorkManager to retry
  } catch (e) {
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'failure',
      detail: e.toString(),
    ));
    return false;
  }
}