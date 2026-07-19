import 'package:uuid/uuid.dart';

import '../conflict/conflict_resolver.dart';
import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';

/// Resolves a single [SyncTransportResult.conflict] — the only job of
/// this class. Pulled out of [SyncRunner] so the send/retry loop doesn't
/// also have to carry conflict-resolution branching inline.
class ConflictHandler {
  ConflictHandler({
    required ConflictResolver resolver,
    required void Function(SyncConflict, Map<String, dynamic>)? onConflict,
  })  : _resolver = resolver,
        _onConflict = onConflict;

  static const _uuid = Uuid();

  final ConflictResolver _resolver;
  final void Function(SyncConflict conflict, Map<String, dynamic> winningData)?
      _onConflict;

  Future<void> resolve({
    required SyncOperation op,
    required SyncAdapter adapter,
    required SyncTransportResult result,
    required LocalStorage storage,
  }) {
    return op.type == SyncOperationType.delete
        ? _resolveDeleteConflict(op, adapter, result, storage)
        : _resolveWriteConflict(op, adapter, result, storage);
  }

  Future<void> _resolveDeleteConflict(
    SyncOperation op,
    SyncAdapter adapter,
    SyncTransportResult result,
    LocalStorage storage,
  ) async {
   
    switch (_resolver.type) {
      case ConflictStrategyType.clientWins:
        await storage.enqueueOperation(SyncOperation(
          id: _uuid.v4(),
          entityName: op.entityName,
          entityId: op.entityId,
          type: SyncOperationType.delete,
          payload: const {},
          createdAt: DateTime.now(),
          localVersion: result.serverVersion!,
        ));
      default:
        await storage.reconcileEntity(
          entityName: op.entityName,
          entityId: op.entityId,
          data: result.serverData!,
          version: result.serverVersion!,
          updatedAt: adapter.updatedAtFromJson(result.serverData!),
          isSynced: true,
        );
    }
    await storage.removeOperation(op.id);
  }

  Future<void> _resolveWriteConflict(
    SyncOperation op,
    SyncAdapter adapter,
    SyncTransportResult result,
    LocalStorage storage,
  ) async {
    final conflict = SyncConflict(
  entityName: op.entityName,
  entityId: op.entityId,
  localData: op.payload,
  localVersion: op.localVersion,
  localUpdatedAt: adapter.updatedAtFromJson(op.payload),
  serverData: result.serverData!,
  serverVersion: result.serverVersion!,
  serverUpdatedAt: adapter.updatedAtFromJson(result.serverData!),
);

    final winningData = await _resolver.resolve(conflict);
    final winnerIsServer = identical(winningData, conflict.serverData);

    await storage.reconcileEntity(
      entityName: op.entityName,
      entityId: op.entityId,
      data: winningData,
      version: conflict.serverVersion,
      updatedAt: winnerIsServer ? conflict.serverUpdatedAt : DateTime.now(),
      isSynced: winnerIsServer,
    );
    await storage.removeOperation(op.id);

    if (!winnerIsServer) {
      await storage.enqueueOperation(SyncOperation(
        id: _uuid.v4(),
        entityName: op.entityName,
        entityId: op.entityId,
        type: SyncOperationType.update,
        payload: winningData,
        createdAt: DateTime.now(),
        localVersion: conflict.serverVersion,
      ));
    }

    _onConflict?.call(conflict, winningData);
  }
}