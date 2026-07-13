import 'sync_operation.dart';

/// Storage contract implemented by concrete database packages
/// (e.g. `offline_sync_drift`, later `offline_sync_isar`).
///
/// `core` never talks to SQLite/Isar/Hive directly — it only depends on
/// this interface. This is what keeps decision #1 in ARCHITECTURE.md real:
/// swapping the storage engine later means writing a new [LocalStorage]
/// implementation, not touching `core`.
abstract class LocalStorage {
  /// Opens the database, runs migrations. Called once from
  /// `OfflineSync.initialize()`.
  Future<void> init();

  // ---- Entities ----

  /// Inserts or updates the JSON snapshot of an entity.
  Future<void> saveEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required DateTime updatedAt,
  });

  /// Soft-deletes an entity (see ARCHITECTURE.md — decision #5).
  Future<void> softDeleteEntity({
    required String entityName,
    required String entityId,
  });

  /// Permanently removes an entity row. Only called after the server has
  /// acknowledged a delete.
  Future<void> hardDeleteEntity({
    required String entityName,
    required String entityId,
  });

  Future<Map<String, dynamic>?> getEntity({
    required String entityName,
    required String entityId,
  });

  /// All non-deleted entities of [entityName].
  Future<List<Map<String, dynamic>>> getAllEntities(String entityName);

  // ---- Queue ----

  Future<void> enqueueOperation(SyncOperation operation);

  /// Operations ready to be attempted right now, oldest first: every
  /// [SyncOperationStatus.pending] row, plus [SyncOperationStatus.failed]
  /// rows whose [SyncOperation.nextRetryAt] is `null` or has already
  /// passed relative to [now]. [SyncOperationStatus.exhausted] rows are
  /// never returned — they've used up their retry budget (see
  /// [RetryPolicy]) and need manual intervention.
  Future<List<SyncOperation>> getPendingOperations({DateTime? now});

  /// Updates an operation after a send attempt.
  ///
  /// [nextRetryAt] is set alongside [SyncOperationStatus.failed] to
  /// schedule the next attempt ([RetryPolicy.nextRetryAt]); leave it
  /// `null` for [SyncOperationStatus.exhausted] (there is no next
  /// attempt) or [SyncOperationStatus.synced].
  Future<void> updateOperationStatus(
    String operationId,
    SyncOperationStatus status, {
    int? retryCount,
    DateTime? nextRetryAt,
  });

  /// Removes an operation once the server has acknowledged it.
  Future<void> removeOperation(String operationId);
}
