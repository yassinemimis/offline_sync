/// Bridges a user's model type [T] with the sync engine.
///
/// Design decision (Phase 0): we use a *registration/adapter* pattern
/// instead of forcing [T] to implement an interface (e.g. `extends Syncable`).
///
/// Why:
/// - Works with any existing model: plain classes, `freezed`, `equatable`,
///   generated `json_serializable` classes, etc. — no inheritance required.
/// - Dart has no runtime reflection in AOT/Flutter builds, so an explicit
///   adapter (functions passed in) is the idiomatic way to teach the engine
///   how to serialize/identify a type, similar to how `Dio`/`Retrofit`
///   generators work.
/// - Keeps `offline_sync_core` fully storage- and network-agnostic: the
///   adapter only describes *shape*, never *how* to store or send it.
class SyncAdapter<T> {
  const SyncAdapter({
    required this.entityName,
    required this.fromJson,
    required this.toJson,
    required this.getId,
    required this.getUpdatedAt,
    required this.endpoint,
    this.isDeleted,
  });

  /// Stable name used as the table name and as the `entityType` stored in
  /// the queue (e.g. `"User"`, `"Order"`). Must be unique per registration.
  final String entityName;

  /// Builds a [T] instance from a decoded JSON map (local DB read or server
  /// response).
  final T Function(Map<String, dynamic> json) fromJson;

  /// Serializes [T] into a JSON map for local storage and for the outgoing
  /// queue payload.
  final Map<String, dynamic> Function(T entity) toJson;

  /// Returns the unique id of an entity. Ids are always `String` at the
  /// core-engine level (adapters are free to generate UUIDs client-side so
  /// records can be created fully offline).
  final String Function(T entity) getId;

  /// Returns the last-modified timestamp, used by the default
  /// "Last Update Wins" conflict strategy and for delta sync (Phase 4).
  final DateTime Function(T entity) getUpdatedAt;

  /// Base REST endpoint for this entity (e.g. `"/api/users"`). Concrete
  /// network adapters (Phase 3) may interpret this differently
  /// (REST vs GraphQL).
  final String endpoint;

  /// Optional: lets the adapter read a soft-delete flag off [T] itself,
  /// for models that already carry a `deleted` field. If omitted, the core
  /// engine tracks deletion purely via queue metadata.
  final bool Function(T entity)? isDeleted;
}
