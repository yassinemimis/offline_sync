import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

import 'app_database.dart';

/// Drift-backed implementation of [LocalStorage].
///
/// This is the piece that turns `OfflineSync.save/sync` from an API
/// surface (Phase 0) into something that actually persists data
/// (Phase 1).
class DriftLocalStorage implements LocalStorage {
  DriftLocalStorage([AppDatabase? database]) : _db = database ?? AppDatabase();

  final AppDatabase _db;

  @override
  Future<void> init() async {
    await _db.customSelect('SELECT 1').get();
  }

  // ---- Entities ----

  @override
  Future<void> saveEntity({
    required String entityName,
    required String entityId,
    required Map<String, dynamic> data,
    required DateTime updatedAt,
  }) async {
    await _db.into(_db.entitiesTable).insertOnConflictUpdate(
          EntitiesTableCompanion.insert(
            entityType: entityName,
            entityId: entityId,
            dataJson: jsonEncode(data),
            updatedAt: updatedAt,
            isSynced: const Value(false),
          ),
        );
  }

  @override
  Future<void> softDeleteEntity({
    required String entityName,
    required String entityId,
  }) async {
    await (_db.update(_db.entitiesTable)
          ..where((t) =>
              t.entityType.equals(entityName) & t.entityId.equals(entityId)))
        .write(const EntitiesTableCompanion(deleted: Value(true)));
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
          ),
        );
  }

  @override
  Future<List<SyncOperation>> getPendingOperations() async {
    final rows = await (_db.select(_db.syncOperationsTable)
          ..where((t) => t.status.equalsValue(SyncOperationStatus.pending) |
              t.status.equalsValue(SyncOperationStatus.failed))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    return rows
        .map((row) => SyncOperation(
              id: row.id,
              entityName: row.entityType,
              entityId: row.entityId,
              type: row.type,
              payload: jsonDecode(row.payloadJson) as Map<String, dynamic>,
              createdAt: row.createdAt,
              status: row.status,
              retryCount: row.retryCount,
            ))
        .toList();
  }

  @override
  Future<void> updateOperationStatus(
    String operationId,
    SyncOperationStatus status, {
    int? retryCount,
  }) async {
    await (_db.update(_db.syncOperationsTable)
          ..where((t) => t.id.equals(operationId)))
        .write(SyncOperationsTableCompanion(
      status: Value(status),
      retryCount: retryCount == null ? const Value.absent() : Value(retryCount),
    ));
  }

  @override
  Future<void> removeOperation(String operationId) async {
    await (_db.delete(_db.syncOperationsTable)
          ..where((t) => t.id.equals(operationId)))
        .go();
  }
}