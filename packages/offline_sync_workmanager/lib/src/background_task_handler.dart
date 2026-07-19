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
/// what [performSync] itself does.
Future<bool> handleBackgroundTask(
  String task,
  Future<void> Function() performSync, {
  Duration timeout = kBackgroundSyncTimeout,
}) async {
  if (task != kOfflineSyncTaskName) {
    return true; // not ours — some other WorkManager task, ignore
  }

  final startedAt = DateTime.now();

  try {
    await performSync().timeout(timeout);
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'success',
    ));
    return true;
  } on TimeoutException {
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'timeout',
      detail: 'exceeded $timeout',
    ));
    return false;
  } catch (e) {
    await BackgroundSyncLog.record(BackgroundSyncAttempt(
      startedAt: startedAt,
      outcome: 'failure',
      detail: e.toString(),
    ));
    return false;
  }
}