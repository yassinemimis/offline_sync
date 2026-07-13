import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';

SyncOperation _op(String id) => SyncOperation(
      id: id,
      entityName: 'Widget',
      entityId: 'w1',
      type: SyncOperationType.create,
      payload: const {},
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  late DriftLocalStorage storage;
  final now = DateTime(2026, 1, 1, 12, 0, 0);

  setUp(() {
    storage = DriftLocalStorage(AppDatabase.withExecutor(NativeDatabase.memory()));
  });

  test('a pending (never-attempted) operation is always eligible', () async {
    await storage.enqueueOperation(_op('op1'));

    final pending = await storage.getPendingOperations(now: now);

    expect(pending, hasLength(1));
  });

  test('a failed operation with nextRetryAt in the future is excluded',
      () async {
    await storage.enqueueOperation(_op('op1'));
    await storage.updateOperationStatus(
      'op1',
      SyncOperationStatus.failed,
      retryCount: 1,
      nextRetryAt: now.add(const Duration(minutes: 5)), // still in the future
    );

    final pending = await storage.getPendingOperations(now: now);

    expect(pending, isEmpty);
  });

  test('a failed operation becomes eligible once nextRetryAt has passed',
      () async {
    await storage.enqueueOperation(_op('op1'));
    await storage.updateOperationStatus(
      'op1',
      SyncOperationStatus.failed,
      retryCount: 1,
      nextRetryAt: now.subtract(const Duration(seconds: 1)), // just passed
    );

    final pending = await storage.getPendingOperations(now: now);

    expect(pending, hasLength(1));
    expect(pending.first.status, SyncOperationStatus.failed);
  });

  test('an exhausted operation is never returned, even long after its '
      'old nextRetryAt', () async {
    await storage.enqueueOperation(_op('op1'));
    await storage.updateOperationStatus(
      'op1',
      SyncOperationStatus.exhausted,
      retryCount: 8,
    );

    final pending = await storage.getPendingOperations(
      now: now.add(const Duration(days: 30)),
    );

    expect(pending, isEmpty);
  });

  test('updateOperationStatus clears nextRetryAt when transitioning to '
      'exhausted (no stale future date left behind)', () async {
    await storage.enqueueOperation(_op('op1'));
    await storage.updateOperationStatus(
      'op1',
      SyncOperationStatus.failed,
      retryCount: 1,
      nextRetryAt: now.add(const Duration(minutes: 5)),
    );
    await storage.updateOperationStatus(
      'op1',
      SyncOperationStatus.exhausted,
      retryCount: 2,
      // nextRetryAt intentionally omitted (null) here.
    );

    // Re-marking it failed with no nextRetryAt should make it immediately
    // eligible again -- proving the earlier future date didn't linger.
    await storage.updateOperationStatus('op1', SyncOperationStatus.failed);
    final pending = await storage.getPendingOperations(now: now);

    expect(pending, hasLength(1));
  });
}
