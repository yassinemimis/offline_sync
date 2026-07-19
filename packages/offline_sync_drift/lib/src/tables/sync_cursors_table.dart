import 'package:drift/drift.dart';

/// One watermark row per entity type, used to resume delta pulls
/// (Phase 7) from where the last successful one left off — see
/// `LocalStorage.getSyncCursor`/`setSyncCursor`.
class SyncCursorsTable extends Table {
  /// Matches `SyncAdapter.entityName` — see `EntitiesTable.entityType`
  /// for why this Dart getter isn't itself named `entityName`.
  TextColumn get entityType => text().named('entityName')();

  DateTimeColumn get lastSyncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {entityType};
}