import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // BackgroundSyncLog.record() calls SharedPreferences.getInstance()
  // internally now — without this, every test throws
  // MissingPluginException the moment handleBackgroundTask tries to log.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('handleBackgroundTask', () {
    test('ignores tasks that are not ours and reports success', () async {
      var performSyncCalled = false;

      final result = await handleBackgroundTask(
        'some_other_plugins_task',
        () async => performSyncCalled = true,
      );

      expect(result, isTrue);
      expect(performSyncCalled, isFalse,
          reason: "shouldn't run our sync for someone else's task");
    });

    test('runs performSync and reports success for our task', () async {
      var performSyncCalled = false;

      final result = await handleBackgroundTask(
        kOfflineSyncTaskName,
        () async => performSyncCalled = true,
      );

      expect(result, isTrue);
      expect(performSyncCalled, isTrue);
    });

    test('reports failure (false) if performSync throws', () async {
      final result = await handleBackgroundTask(
        kOfflineSyncTaskName,
        () async => throw Exception('network unreachable'),
      );

      expect(result, isFalse,
          reason: 'false tells WorkManager to retry per its own backoff');
    });

    test('reports failure (false) on timeout, without waiting the real '
        'kBackgroundSyncTimeout duration', () async {
      final result = await handleBackgroundTask(
        kOfflineSyncTaskName,
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
        timeout: const Duration(milliseconds: 20),
      );

      expect(result, isFalse,
          reason: 'a hung sync call must not block WorkManager forever');
    });

    test('records a success attempt in BackgroundSyncLog', () async {
      await handleBackgroundTask(
        kOfflineSyncTaskName,
        () async {},
      );

      final attempts = await BackgroundSyncLog.recentAttempts();

      expect(attempts, isNotEmpty);
      expect(attempts.last.outcome, 'success');
    });

    test('records a failure attempt with the error message as detail',
        () async {
      await handleBackgroundTask(
        kOfflineSyncTaskName,
        () async => throw Exception('boom'),
      );

      final attempts = await BackgroundSyncLog.recentAttempts();

      expect(attempts, isNotEmpty);
      expect(attempts.last.outcome, 'failure');
      expect(attempts.last.detail, contains('boom'));
    });

    test('records a timeout attempt distinctly from a failure', () async {
      await handleBackgroundTask(
        kOfflineSyncTaskName,
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
        timeout: const Duration(milliseconds: 20),
      );

      final attempts = await BackgroundSyncLog.recentAttempts();

      expect(attempts, isNotEmpty);
      expect(attempts.last.outcome, 'timeout');
    });
  });
}