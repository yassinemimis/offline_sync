import 'sync_adapter.dart';

/// One changed (or deleted) record returned by a delta fetch.
class DeltaRecord {
  const DeltaRecord({
    required this.entityId,
    required this.data,
    required this.version,
    required this.updatedAt,
    this.deleted = false,
  });

  /// The affected entity's id. Kept separate from [data] (rather than
  /// requiring callers to dig it out of the JSON) so a `deleted: true`
  /// record — which may carry little or no other data — can still be
  /// routed to the right local row.
  final String entityId;

  /// The entity's current JSON shape, as produced by the server —
  /// decodable via the matching `SyncAdapter.fromJson`. Not meaningful
  /// when [deleted] is `true`.
  final Map<String, dynamic> data;

  /// The entity's current server-side version — becomes the new local
  /// baseline (`EntitiesTable.version`) once reconciled.
  final int version;

  final DateTime updatedAt;

  /// Mirrors the client's own soft-delete convention (ARCHITECTURE.md
  /// decision #5), in the opposite direction: the server is telling the
  /// client this record no longer exists.
  final bool deleted;
}

/// Result of a single [DeltaSyncTransport.fetchChanges] call.
class DeltaFetchResult {
  const DeltaFetchResult({
    required this.records,
    required this.fetchedAt,
  });

  /// Every record the server reports as changed (or deleted) since the
  /// cursor passed to `fetchChanges`. Empty if nothing changed.
  final List<DeltaRecord> records;

  /// Timestamp to persist as the new cursor once [records] has been
  /// fully reconciled locally — see `LocalStorage.setSyncCursor`.
  ///
  /// Deliberately supplied by the transport rather than computed as
  /// `DateTime.now()` by the caller: a transport talking to a server
  /// with clock skew, or one that paginates across multiple requests,
  /// needs to control this "as-of" watermark precisely.
  final DateTime fetchedAt;
}

/// Optional capability: fetches server-side changes for pull-based
/// (delta) sync.
///
/// Deliberately **not** a method on [SyncTransport] itself — adding a
/// new required method there would break every existing implementation
/// (including third-party ones outside this repo, and the example in
/// `Network_Layer.mdx`). A transport that supports pull implements both
/// interfaces:
///
/// ```dart
/// class DioSyncTransport implements SyncTransport, DeltaSyncTransport { ... }
/// ```
///
/// The engine checks `transport is DeltaSyncTransport` at the call site
/// and fails with a clear `StateError` if it isn't — see
/// `OfflineSync.pull`.
abstract class DeltaSyncTransport {
  /// Fetches everything the server reports as changed for [adapter]'s
  /// entity type since [since] — the previous call's
  /// [DeltaFetchResult.fetchedAt], or `null` for "fetch everything"
  /// (the first pull for this entity type).
  Future<DeltaFetchResult> fetchChanges(
    SyncAdapter adapter, {
    DateTime? since,
  });
}