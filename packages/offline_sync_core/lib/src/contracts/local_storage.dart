import 'sync_operation.dart';

/// Storage contract implemented by concrete database packages
/// (e.g. `offline_sync_drift`, later `offline_sync_isar`).
abstract class LocalStorage {
  Future<void> init();

  // ---- Entities ----

  /// Inserts or updates the JSON snapshot of an entity.
  ///
  /// IMPORTANT: this does **not** bump `version`. `version` means "the
  /// version last confirmed with the server", not a count of local edits
  /// — bumping it on every local write would break optimistic concurrency
  /// (the client would claim a baseline the server never acknowledged).
  /// Returns the entity's *current* version unchanged, so the caller can
  /// attach it to the queued operation as `SyncOperation.localVersion`.
  /// New entities start at version `0`.
  Future<int> saveEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required DateTime updatedAt,
  });

  /// Soft-deletes an entity (ARCHITECTURE.md decision #5). Same version
  /// semantics as [saveEntity]: returns the current baseline, unchanged.
  Future<int> softDeleteEntity({
    required String entityName,
    required String entityId,
  });

  /// Permanently removes a row. Only called after the server has
  /// acknowledged a delete.
  Future<void> hardDeleteEntity({
    required String entityName,
    required String entityId,
  });

/// Called after a create/update operation is confirmed synced. Uses
/// [serverVersion] as the new baseline if the transport captured one
/// from the response; otherwise falls back to incrementing by one.
/// Returns the entity's new version.
Future<int> markSynced({
  required String entityName,
  required String entityId,
  int? serverVersion,
});

  /// Writes back the result of conflict resolution: [data] becomes the
  /// row's content, [version] becomes its new baseline (the server's
  /// version at the time of the conflict), and [isSynced] reflects
  /// whether that content still needs pushing (`false` if the winning
  /// data was the client's and hasn't reached the server yet).
  Future<void> reconcileEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required int version,
    required DateTime updatedAt,
    required bool isSynced,
  });

  Future<Map<String, dynamic>?> getEntity({
    required String entityName,
    required String entityId,
  });

  Future<List<Map<String, dynamic>>> getAllEntities(String entityName);

  // ---- Queue ----

  Future<void> enqueueOperation(SyncOperation operation);

  Future<List<SyncOperation>> getPendingOperations({DateTime? now});

  Future<void> updateOperationStatus(
    String operationId,
    SyncOperationStatus status, {
    int? retryCount,
    DateTime? nextRetryAt,
  });

  Future<void> removeOperation(String operationId);

  /// Every operation still in the queue, regardless of whether it's
/// eligible to be attempted right now — unlike [getPendingOperations],
/// this includes `failed` rows still waiting out their backoff window.
/// Meant for UI display ("3 changes not yet synced"), not for driving
/// the sync loop itself.
Future<int> totalQueuedOperationsCount();
}