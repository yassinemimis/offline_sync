import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

import 'app_database.dart';

class DriftLocalStorage implements LocalStorage {
  DriftLocalStorage([AppDatabase? database]) : _db = database ?? AppDatabase();

  final AppDatabase _db;

  @override
  Future<void> init() async {
    await _db.customSelect('SELECT 1').get();
  }

  // ---- Entities ----

  @override
  Future<int> saveEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required DateTime updatedAt,
  }) async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.entitiesTable)
            ..where((t) =>
                t.entityType.equals(entityName) &
                t.entityId.equals(entityId)))
          .getSingleOrNull();
      final baselineVersion = existing?.version ?? 0;

      await _db.into(_db.entitiesTable).insertOnConflictUpdate(
            EntitiesTableCompanion.insert(
              entityType: entityName,
              entityId: entityId,
              dataJson: jsonEncode(data),
              updatedAt: updatedAt,
              isSynced: const Value(false),
              version: Value(baselineVersion),
            ),
          );
      return baselineVersion;
    });
  }

  @override
  Future<int> softDeleteEntity({
    required String entityName,
    required String entityId,
  }) async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.entitiesTable)
            ..where((t) =>
                t.entityType.equals(entityName) &
                t.entityId.equals(entityId)))
          .getSingleOrNull();
      final baselineVersion = existing?.version ?? 0;

      await (_db.update(_db.entitiesTable)
            ..where((t) =>
                t.entityType.equals(entityName) &
                t.entityId.equals(entityId)))
          .write(const EntitiesTableCompanion(
        deleted: Value(true),
        isSynced: Value(false),
      ));
      return baselineVersion;
    });
  }

  @override
  Future<void> hardDeleteEntity({
    required String entityName,
    required String entityId,
  }) async {
    await (_db.delete(_db.entitiesTable)
          ..where((t) =>
              t.entityType.equals(entityName) & t.entityId.equals(entityId)))
        .go();
  }

  @override
  Future<int> markSynced({
    required String entityName,
    required String entityId,
    int? serverVersion,
  }) async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.entitiesTable)
            ..where((t) =>
                t.entityType.equals(entityName) &
                t.entityId.equals(entityId)))
          .getSingleOrNull();
      if (existing == null) return 0;

      final newVersion = serverVersion ?? existing.version + 1;

      await (_db.update(_db.entitiesTable)
            ..where((t) =>
                t.entityType.equals(entityName) &
                t.entityId.equals(entityId)))
          .write(EntitiesTableCompanion(
        version: Value(newVersion),
        isSynced: const Value(true),
      ));
      return newVersion;
    });
  }

  @override
  Future<void> reconcileEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required int version,
    required DateTime updatedAt,
    required bool isSynced,
  }) async {
    await _db.into(_db.entitiesTable).insertOnConflictUpdate(
          EntitiesTableCompanion.insert(
            entityType: entityName,
            entityId: entityId,
            dataJson: jsonEncode(data),
            updatedAt: updatedAt,
            version: Value(version),
            isSynced: Value(isSynced),
            deleted: const Value(false),
          ),
        );
  }

  @override
  Future<Map<String, dynamic>?> getEntity({
    required String entityName,
    required String entityId,
  }) async {
    final row = await (_db.select(_db.entitiesTable)
          ..where((t) =>
              t.entityType.equals(entityName) & t.entityId.equals(entityId)))
        .getSingleOrNull();
    if (row == null || row.deleted) return null;
    return jsonDecode(row.dataJson) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> getAllEntities(String entityName) async {
    final rows = await (_db.select(_db.entitiesTable)
          ..where((t) =>
              t.entityType.equals(entityName) & t.deleted.equals(false)))
        .get();
    return rows
        .map((row) => jsonDecode(row.dataJson) as Map<String, dynamic>)
        .toList();
  }

  // ---- Queue ----

  @override
  Future<void> enqueueOperation(SyncOperation operation) async {
    await _db.into(_db.syncOperationsTable).insert(
          SyncOperationsTableCompanion.insert(
            id: operation.id,
            entityType: operation.entityName,
            entityId: operation.entityId,
            type: operation.type,
            payloadJson: jsonEncode(operation.payload),
            createdAt: operation.createdAt,
            status: Value(operation.status),
            retryCount: Value(operation.retryCount),
            localVersion: Value(operation.localVersion),
          ),
        );
  }

  @override
  Future<List<SyncOperation>> getPendingOperations({DateTime? now}) async {
    final cutoff = now ?? DateTime.now();

    final rows = await (_db.select(_db.syncOperationsTable)
          ..where((t) =>
              t.status.equalsValue(SyncOperationStatus.pending) |
              (t.status.equalsValue(SyncOperationStatus.failed) &
                  (t.nextRetryAt.isNull() |
                      t.nextRetryAt.isSmallerOrEqualValue(cutoff))))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    return rows.map(_operationFromRow).toList();
  }

  @override
  Future<void> updateOperationStatus(
    String operationId,
    SyncOperationStatus status, {
    int? retryCount,
    DateTime? nextRetryAt,
  }) async {
    await (_db.update(_db.syncOperationsTable)
          ..where((t) => t.id.equals(operationId)))
        .write(SyncOperationsTableCompanion(
      status: Value(status),
      retryCount:
          retryCount == null ? const Value.absent() : Value(retryCount),
      nextRetryAt: Value(nextRetryAt),
    ));
  }

  @override
  Future<void> removeOperation(String operationId) async {
    await (_db.delete(_db.syncOperationsTable)
          ..where((t) => t.id.equals(operationId)))
        .go();
  }

  @override
  Future<int> totalQueuedOperationsCount() async {
    final rows = await _db.select(_db.syncOperationsTable).get();
    return rows.length;
  }

  @override
  Future<List<SyncOperation>> getOperationsForEntity({
    required String entityName,
    required String entityId,
  }) async {
    final rows = await (_db.select(_db.syncOperationsTable)
          ..where((t) =>
              t.entityType.equals(entityName) & t.entityId.equals(entityId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    return rows.map(_operationFromRow).toList();
  }

  SyncOperation _operationFromRow(SyncOperationsTableData row) {
    return SyncOperation(
      id: row.id,
      entityName: row.entityType,
      entityId: row.entityId,
      type: row.type,
      payload: jsonDecode(row.payloadJson) as Map<String, dynamic>,
      createdAt: row.createdAt,
      status: row.status,
      retryCount: row.retryCount,
      nextRetryAt: row.nextRetryAt,
      localVersion: row.localVersion,
    );
  }

  // ---- Delta sync cursor ----

  @override
  Future<DateTime?> getSyncCursor(String entityName) async {
    final row = await (_db.select(_db.syncCursorsTable)
          ..where((t) => t.entityType.equals(entityName)))
        .getSingleOrNull();
    return row?.lastSyncedAt;
  }

  @override
  Future<void> setSyncCursor(String entityName, DateTime cursor) async {
    await _db.into(_db.syncCursorsTable).insertOnConflictUpdate(
          SyncCursorsTableCompanion.insert(
            entityType: entityName,
            lastSyncedAt: cursor,
          ),
        );
  }
}