import 'sync_adapter.dart';
import 'sync_operation.dart';

/// Outcome of attempting to send a single [SyncOperation].
class SyncTransportResult {
  /// The operation was acknowledged by the server. Safe to remove from
  /// the queue.
  const SyncTransportResult.success()
      : isSuccess = true,
        retriable = false,
        message = null;

  /// The operation was not acknowledged.
  ///
  /// [retriable] distinguishes failures worth retrying (timeout, 5xx,
  /// no connection) from ones that never will be (4xx validation error,
  /// malformed payload) — consumed by the retry/backoff strategy
  /// (Phase 3). Phase 2 doesn't act on it yet; every failure is simply
  /// marked [SyncOperationStatus.failed].
  const SyncTransportResult.failure({this.retriable = true, this.message})
      : isSuccess = false;

  final bool isSuccess;
  final bool retriable;

  /// Optional human-readable reason, for logging (Phase 10).
  final String? message;
}

/// Sends a single queued [SyncOperation] to a server.
///
/// Mirrors [LocalStorage]: `core` depends only on this interface, never on
/// a concrete HTTP client. This is what keeps `offline_sync_core` free of
/// a `dio`/`http` dependency, and what lets `offline_sync_dio`,
/// `offline_sync_graphql`, etc. exist as independent, swappable packages
/// (see ARCHITECTURE.md, decision #1, which makes the same argument for
/// storage).
///
/// A concrete implementation owns:
/// - Mapping [SyncOperationType] to an HTTP verb (or GraphQL
///   mutation/Firestore call/...).
/// - Auth headers, base URL, interceptors — anything client-specific.
/// - Translating a transport-level failure (timeout, 4xx, 5xx, no
///   connection) into a [SyncTransportResult].
abstract class SyncTransport {
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  );
}