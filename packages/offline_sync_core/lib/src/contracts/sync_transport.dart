import 'sync_adapter.dart';
import 'sync_operation.dart';

/// Outcome of attempting to send a single [SyncOperation].
class SyncTransportResult {
  /// The operation was acknowledged by the server. Safe to remove from
  /// the queue.
/// The operation was acknowledged by the server. Safe to remove from
/// the queue.
///
/// [serverVersion] is the entity's new version *as the server sees it*
/// after this write, if the transport implementation captured it from
/// the response. When `null`, `LocalStorage.markSynced` falls back to
/// assuming the server incremented by exactly one.
const SyncTransportResult.success({this.serverVersion, this.serverData})
    : isSuccess = true,
      isConflict = false,
      retriable = false,
      message = null;

  /// The operation was not acknowledged.
  ///
  /// [retriable] distinguishes failures worth retrying (timeout, 5xx,
  /// no connection) from ones that never will be (4xx validation error,
  /// malformed payload) — consumed by the retry/backoff policy.
  const SyncTransportResult.failure({this.retriable = true, this.message})
      : isSuccess = false,
        isConflict = false,
        serverData = null,
        serverVersion = null;

  /// The server rejected the write because the client's optimistic-
  /// concurrency token (`SyncOperation.localVersion`) didn't match what
  /// the server currently has (HTTP 409 by convention). [serverData] is
  /// the server's current copy of the entity; [serverVersion] is its
  /// current version. `sync()` hands both to the configured
  /// `ConflictResolver`.
  const SyncTransportResult.conflict({
    required Map<String, dynamic> serverData,
    required int serverVersion,
  })  : isSuccess = false,
        isConflict = true,
        retriable = false,
        message = null,
        serverData = serverData,
        serverVersion = serverVersion;

  final bool isSuccess;
  final bool isConflict;
  final bool retriable;
  final String? message;
  final Map<String, dynamic>? serverData;
  final int? serverVersion;
}

/// Sends a single queued [SyncOperation] to a server.
///
/// Mirrors [LocalStorage]: `core` depends only on this interface, never on
/// a concrete HTTP client — see ARCHITECTURE.md, decision #1.
abstract class SyncTransport {
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  );
}