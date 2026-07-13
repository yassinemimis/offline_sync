/// The kind of change a queued operation represents.
///
/// We queue *operations*, not raw data snapshots — see ARCHITECTURE.md,
/// "Why Queue and not Data". A `delete` must reach the server as a DELETE
/// call, not as a diff of missing fields.
enum SyncOperationType { create, update, delete }

/// Lifecycle status of a queued operation.
enum SyncOperationStatus {
  /// Waiting to be sent for the first time.
  pending,

  /// Currently being sent to the server.
  inProgress,

  /// A send attempt failed but is still within the retry budget
  /// ([RetryPolicy.maxAttempts]). Picked up again once [SyncOperation.
  /// nextRetryAt] has passed.
  failed,

  /// Every retry attempt has been used up ([RetryPolicy.maxAttempts])
  /// without success, or the server rejected the operation in a way that
  /// will never succeed on its own (a non-retriable [SyncTransportResult],
  /// e.g. a 4xx). No longer retried automatically — needs manual
  /// intervention (inspect and re-enqueue, or discard).
  exhausted,

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
    this.nextRetryAt,
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

  /// Incremented on every failed send attempt; consumed by [RetryPolicy].
  final int retryCount;

  /// Earliest time this operation should be attempted again, set by
  /// [RetryPolicy.nextRetryAt] after a retriable failure. `null` for
  /// operations that have never failed (still [SyncOperationStatus.
  /// pending]) — those are always eligible immediately.
  final DateTime? nextRetryAt;

  SyncOperation copyWith({
    SyncOperationStatus? status,
    int? retryCount,
    DateTime? nextRetryAt,
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
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
    );
  }
}
