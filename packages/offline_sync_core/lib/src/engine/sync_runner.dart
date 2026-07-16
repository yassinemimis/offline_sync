import 'package:flutter/foundation.dart';

import '../contracts/local_storage.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';
import '../retry/retry_policy.dart';
import 'adapter_registry.dart';
import 'conflict_handler.dart';

/// Drains the sync queue: sends every eligible [SyncOperation] through
/// [SyncTransport], applies [RetryPolicy] on failure, and delegates
/// conflicts to [ConflictHandler]. De-duplicates concurrent [run] calls
/// so a manual sync and an auto-sync triggered by connectivity coming
/// back can never race over the same queue.
class SyncRunner {
  SyncRunner({
    required LocalStorage storage,
    required SyncTransport transport,
    required RetryPolicy retryPolicy,
    required AdapterRegistry adapters,
    required ConflictHandler conflictHandler,
  })  : _storage = storage,
        _transport = transport,
        _retryPolicy = retryPolicy,
        _adapters = adapters,
        _conflictHandler = conflictHandler;

  final LocalStorage _storage;
  final SyncTransport _transport;
  final RetryPolicy _retryPolicy;
  final AdapterRegistry _adapters;
  final ConflictHandler _conflictHandler;

  Future<void>? _inFlight;

  /// A second concurrent call awaits the same in-flight pass instead of
  /// starting an overlapping one.
  Future<void> run() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = _run();
    _inFlight = future;
    future.whenComplete(() => _inFlight = null);
    return future;
  }

  Future<void> _run() async {
    final now = DateTime.now();
    final pending = await _storage.getPendingOperations(now: now);

    for (final op in pending) {
      final adapter = _adapters.byEntityName(op.entityName);
      if (adapter == null) continue;

     try {
  final result = await _transport.send(op, adapter);

  if (result.isSuccess) {
    await _handleSuccess(op, result);
    continue;
  }

  if (result.isConflict) {
    await _conflictHandler.resolve(
      op: op,
      adapter: adapter,
      result: result,
      storage: _storage,
    );
    continue;
  }

  await _handleFailure(op, result, now);
} catch (_) {
  // Don't let one bad operation take down the rest of the queue.
  await _storage.updateOperationStatus(
    op.id,
    SyncOperationStatus.exhausted,
    retryCount: op.retryCount + 1,
  );
}
    }
  }

  Future<void> _handleSuccess(SyncOperation op, SyncTransportResult result) async {
    if (op.type == SyncOperationType.delete) {
      await _storage.hardDeleteEntity(
          entityName: op.entityName, entityId: op.entityId);
    } else {
      await _storage.markSynced(
        entityName: op.entityName,
        entityId: op.entityId,
        serverVersion: result.serverVersion,
      );
    }
    await _storage.removeOperation(op.id);
  }

  Future<void> _handleFailure(
    SyncOperation op,
    SyncTransportResult result,
    DateTime now,
  ) async {
    final newRetryCount = op.retryCount + 1;
    final canRetry =
        result.retriable && _retryPolicy.hasAttemptsLeft(newRetryCount);

    if (canRetry) {
      await _storage.updateOperationStatus(
        op.id,
        SyncOperationStatus.failed,
        retryCount: newRetryCount,
        nextRetryAt: _retryPolicy.nextRetryAt(newRetryCount, now: now),
      );
    } else {
      await _storage.updateOperationStatus(
        op.id,
        SyncOperationStatus.exhausted,
        retryCount: newRetryCount,
      );
    }
  }
}