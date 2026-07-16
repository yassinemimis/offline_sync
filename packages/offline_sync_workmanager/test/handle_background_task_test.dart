import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';

void main() {
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
  });
}