import '../contracts/delta_sync_transport.dart';
import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_transport.dart';
import 'adapter_registry.dart';
import 'conflict_handler.dart';

/// Fetches server-side changes for one entity type via
/// [DeltaSyncTransport.fetchChanges] and reconciles them locally.
///
/// Single responsibility: apply pulled [DeltaRecord]s. It does **not**
/// duplicate conflict-resolution logic — a pulled record that collides
/// with an unsynced local change is handed to the exact same
/// [ConflictHandler] used by [SyncRunner] for 409s, so both discovery
/// paths (push rejection vs. pull) resolve identically.
class DeltaPuller {
  DeltaPuller({
    required LocalStorage storage,
    required AdapterRegistry adapters,
    required ConflictHandler conflictHandler,
  })  : _storage = storage,
        _adapters = adapters,
        _conflictHandler = conflictHandler;

  final LocalStorage _storage;
  final AdapterRegistry _adapters;
  final ConflictHandler _conflictHandler;

  Future<void> pull(String entityName, DeltaSyncTransport transport) async {
    final adapter = _adapters.byEntityName(entityName);
    if (adapter == null) {
      throw StateError(
        'No SyncAdapter registered for entityName "$entityName". '
        'Call OfflineSync.register(...) first.',
      );
    }

    final since = await _storage.getSyncCursor(entityName);
    final result = await transport.fetchChanges(adapter, since: since);

    for (final record in result.records) {
      await _reconcileRecord(entityName, adapter, record);
    }

    // Only advance the cursor after every record in this batch has been
    // fully reconciled — see LocalStorage.setSyncCursor docs. If
    // reconciliation throws partway through, the cursor stays put and
    // the next pull retries the whole batch (records are idempotent to
    // re-apply — reconcileEntity/hardDeleteEntity are both upserts).
    await _storage.setSyncCursor(entityName, result.fetchedAt);
  }

  Future<void> _reconcileRecord(
    String entityName,
    SyncAdapter adapter,
    DeltaRecord record,
  ) async {
    final localOps = await _storage.getOperationsForEntity(
      entityName: entityName,
      entityId: record.entityId,
    );

    if (localOps.isEmpty) {
      // No competing local change — the server's copy is authoritative.
      if (record.deleted) {
        await _storage.hardDeleteEntity(
          entityName: entityName,
          entityId: record.entityId,
        );
      } else {
        await _storage.reconcileEntity(
          entityName: entityName,
          entityId: record.entityId,
          data: record.data,
          version: record.version,
          updatedAt: record.updatedAt,
          isSynced: true,
        );
      }
      return;
    }

    if (record.deleted) {
      // The server no longer has this record, but there's an unsynced
      // local change competing for it. This isn't a data-vs-data
      // conflict ConflictHandler is built to resolve (there's no server
      // data to compare against — just "gone"). Deliberately out of
      // scope for this pass: defaults to the server's authority and
      // discards the local change. Recreating a server-deleted resource
      // to honor "client wins" here would need different semantics —
      // flagging for a follow-up design discussion rather than guessing.
      for (final op in localOps) {
        await _storage.removeOperation(op.id);
      }
      await _storage.hardDeleteEntity(
        entityName: entityName,
        entityId: record.entityId,
      );
      return;
    }

    // Genuine conflict: reuse the same resolution path a 409 goes
    // through. The most recently queued local operation best represents
    // current local intent (its payload/localVersion are the freshest).
    localOps.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final representativeOp = localOps.last;

    // Any other queued ops for this entity are superseded once this
    // conflict resolves — leaving them would resend stale payloads
    // against a baseline that's about to change underneath them.
    for (final op in localOps) {
      if (op.id != representativeOp.id) {
        await _storage.removeOperation(op.id);
      }
    }

    await _conflictHandler.resolve(
      op: representativeOp,
      adapter: adapter,
      result: SyncTransportResult.conflict(
        serverData: record.data,
        serverVersion: record.version,
      ),
      storage: _storage,
    );
  }
}