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

  /// Decodes [json] and immediately extracts its `updatedAt`, in one
  /// call. Exists specifically so calling code that only has a
  /// *raw*-typed `SyncAdapter` reference (e.g. looked up by
  /// `entityName` via `AdapterRegistry.byEntityName`, which has no
  /// compile-time `T` to work with) can still get the updatedAt safely.
  ///
  /// Reading `getUpdatedAt` as a standalone field value through a raw
  /// `SyncAdapter` reference is unsound in Dart — `T` appears in
  /// *input* position (`DateTime Function(T)`), so the runtime downcast
  /// Dart inserts at the field-read site can fail with a `TypeError`
  /// even though the underlying call would have worked fine. Wrapping
  /// it in a method whose own signature never mentions `T` sidesteps
  /// the problem entirely — `T` stays safely bound inside this method's
  /// body instead of leaking into the type of a value read from outside.
  DateTime updatedAtFromJson(Map<String, dynamic> json) =>
      getUpdatedAt(fromJson(json));
}
