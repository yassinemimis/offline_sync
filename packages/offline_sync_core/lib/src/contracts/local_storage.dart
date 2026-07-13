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

  /// Pending/failed operations, oldest first — the order they must be
  /// replayed in.
  Future<List<SyncOperation>> getPendingOperations();

  Future<void> updateOperationStatus(
    String operationId,
    SyncOperationStatus status, {
    int? retryCount,
  });

  /// Removes an operation once the server has acknowledged it.
  Future<void> removeOperation(String operationId);
}
