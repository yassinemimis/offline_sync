/// The kind of change a queued operation represents.
///
/// We queue *operations*, not raw data snapshots — see ARCHITECTURE.md,
/// "Why Queue and not Data". A `delete` must reach the server as a DELETE
/// call, not as a diff of missing fields.
enum SyncOperationType { create, update, delete }

/// Lifecycle status of a queued operation.
enum SyncOperationStatus {
  /// Waiting to be sent.
  pending,

  /// Currently being sent to the server.
  inProgress,

  /// Send failed; will be retried (Phase 2 - retry/backoff).
  failed,

  /// Sent and acknowledged by the server. Safe to remove from the queue.
  synced,
}

/// A single entry in the offline queue.
///
/// One [SyncOperation] is created for every local mutation
/// (`OfflineSync.save`, `OfflineSync.delete`, ...). The engine replays
/// these in order once connectivity is restored.
class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.entityName,
    required this.entityId,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.status = SyncOperationStatus.pending,
    this.retryCount = 0,
  });

  /// Queue-row id (not the entity id).
  final String id;

  /// Matches [SyncAdapter.entityName], used to route the operation back to
  /// the right adapter/endpoint during sync.
  final String entityName;

  /// The id of the affected entity (matches [SyncAdapter.getId]).
  final String entityId;

  final SyncOperationType type;

  /// JSON snapshot of the entity at queue time (empty map for `delete`).
  final Map<String, dynamic> payload;

  final DateTime createdAt;

  final SyncOperationStatus status;

  /// Incremented on every failed send attempt; consumed by the retry/
  /// backoff strategy in Phase 2.
  final int retryCount;

  SyncOperation copyWith({
    SyncOperationStatus? status,
    int? retryCount,
  }) {
    return SyncOperation(
      id: id,
      entityName: entityName,
      entityId: entityId,
      type: type,
      payload: payload,
      createdAt: createdAt,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
    );
  }
}
