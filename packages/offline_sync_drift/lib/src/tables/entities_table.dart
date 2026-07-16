import 'package:drift/drift.dart';

/// Generic entity store: one row per (entityName, entityId), regardless of
/// which Dart type it came from.
///
/// Why generic and not one Drift table per Model: `core` has no compile-time
/// knowledge of the developer's types (see ARCHITECTURE.md — adapter
/// pattern, decision #2). Storing a JSON snapshot here keeps `offline_sync_drift`
/// closed — it never needs regenerating when someone registers a new
/// `SyncAdapter<T>` in their app.
@DataClassName('EntityRow')
class EntitiesTable extends Table {
  /// Matches [SyncAdapter.entityName], e.g. "User".
  TextColumn get entityType => text().named('entityName')();


  /// Matches [SyncAdapter.getId] output.
  TextColumn get entityId => text()();

  /// JSON-encoded entity, produced by [SyncAdapter.toJson].
  TextColumn get dataJson => text()();

  DateTimeColumn get updatedAt => dateTime()();

  /// True once the last change to this row has been acknowledged by the
  /// server (i.e. no pending queue operation references it).
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();

  /// Soft-delete flag — see ARCHITECTURE.md decision #5. Rows with
  /// `deleted = true` are excluded from `getAllEntities` reads.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

 /// Bumped only by `LocalStorage.markSynced`, to "the version last
/// confirmed with the server" — never on a plain local write (see
/// `LocalStorage.saveEntity` docs). New/never-synced rows are `0`.
IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {entityType, entityId};

}
