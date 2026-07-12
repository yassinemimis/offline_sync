import 'package:drift/drift.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

/// The offline queue. One row per mutation waiting to be sent to the
/// server. Read in [createdAt] order and replayed sequentially by the
/// sync engine — see ARCHITECTURE.md and the product doc's "why Queue and
/// not Data" section.
class SyncOperationsTable extends Table {
  /// Queue-row id (uuid), not the entity id.
  TextColumn get id => text()();

  TextColumn get entityType => text().named('entityName')();

  TextColumn get entityId => text()();

  /// Stored as the enum name ("create" / "update" / "delete").
  TextColumn get type =>
      textEnum<SyncOperationType>()();

  /// JSON snapshot of the entity at the time it was queued (empty object
  /// for `delete`).
  TextColumn get payloadJson => text()();

  DateTimeColumn get createdAt => dateTime()();

  TextColumn get status => textEnum<SyncOperationStatus>()
      .withDefault(Constant(SyncOperationStatus.pending.name))();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
