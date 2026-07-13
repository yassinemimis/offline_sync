import 'package:uuid/uuid.dart';

import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';

/// Public entry point of the library.
///
/// Phase 1 status: `register`, `save`, `delete`, `getAll` are fully
/// implemented against [LocalStorage] — local writes and the queue work
/// end-to-end. `sync()` still only drains the queue locally (marks
/// operations synced) because it has no network transport yet — that
/// lands with the `network` module, next.
///
/// ```dart
/// await OfflineSync.initialize(storage: DriftLocalStorage());
/// OfflineSync.register<User>(userAdapter);
/// await OfflineSync.save(user);
/// await OfflineSync.sync();
/// ```
class OfflineSync {
  OfflineSync._();

  static const _uuid = Uuid();

  static bool _initialized = false;
  static LocalStorage? _storage;
  static final Map<Type, SyncAdapter> _adapters = {};

  /// Opens local storage and runs migrations. [storage] is injected so
  /// `core` never depends on a concrete database package directly —
  /// pass `DriftLocalStorage()` from `offline_sync_drift`.
  static Future<void> initialize({required LocalStorage storage}) async {
    _storage = storage;
    await storage.init();
    _initialized = true;
  }

  /// Registers a [SyncAdapter] for type [T]. Must be called once per model
  /// before saving/reading instances of that type.
  static void register<T>(SyncAdapter<T> adapter) {
    _adapters[T] = adapter;
  }

  /// Saves [entity] to local storage immediately and enqueues a
  /// create/update operation. Returns as soon as the *local* write
  /// succeeds — network sync happens separately, via [sync].
  static Future<void> save<T>(T entity) async {
    final adapter = _requireAdapter<T>();
    final storage = _requireStorage();

    final id = adapter.getId(entity);
    final updatedAt = adapter.getUpdatedAt(entity);
    final json = adapter.toJson(entity);

    // Read first so we know whether this is a create or an update — the
    // server needs to know which HTTP verb to use.
    final existing = await storage.getEntity(
      entityName: adapter.entityName,
      entityId: id,
    );

    await storage.saveEntity(
      entityName: adapter.entityName,
      entityId: id,
      data: json,
      updatedAt: updatedAt,
    );

    await storage.enqueueOperation(SyncOperation(
      id: _uuid.v4(),
      entityName: adapter.entityName,
      entityId: id,
      type: existing == null
          ? SyncOperationType.create
          : SyncOperationType.update,
      payload: json,
      createdAt: DateTime.now(),
    ));
  }

  /// Soft-deletes the entity with [id] locally and enqueues a delete
  /// operation.
  static Future<void> delete<T>(String id) async {
    final adapter = _requireAdapter<T>();
    final storage = _requireStorage();

    await storage.softDeleteEntity(entityName: adapter.entityName, entityId: id);

    await storage.enqueueOperation(SyncOperation(
      id: _uuid.v4(),
      entityName: adapter.entityName,
      entityId: id,
      type: SyncOperationType.delete,
      payload: const {},
      createdAt: DateTime.now(),
    ));
  }

  /// Reads all locally stored, non-deleted instances of [T].
  static Future<List<T>> getAll<T>() async {
    final adapter = _requireAdapter<T>() as SyncAdapter<T>;
    final storage = _requireStorage();

    final rows = await storage.getAllEntities(adapter.entityName);
    return rows.map(adapter.fromJson).toList();
  }

  /// Drains the queue. Phase 1: no network transport yet, so this only
  /// marks every pending operation as synced and removes it — enough to
  /// prove the local write → queue → drain loop end-to-end. Phase 1's
  /// `network` module replaces the body with real HTTP calls, retry, and
  /// conflict handling.
  static Future<void> sync() async {
    final storage = _requireStorage();
    final pending = await storage.getPendingOperations();

    for (final op in pending) {
      // TODO(network module): send `op` to `adapters[op.entityName].endpoint`
      // via HTTP here. On success, remove it. On failure, mark `failed`
      // and increment retryCount instead of removing.
      await storage.removeOperation(op.id);
    }
  }

  static SyncAdapter<T> _requireAdapter<T>() {
    final adapter = _adapters[T];
    if (adapter == null) {
      throw StateError(
        'No SyncAdapter registered for type $T. '
        'Call OfflineSync.register<$T>(adapter) first.',
      );
    }
    return adapter as SyncAdapter<T>;
  }

  static LocalStorage _requireStorage() {
    if (!_initialized || _storage == null) {
      throw StateError(
        'Call OfflineSync.initialize(storage: ...) first.',
      );
    }
    return _storage!;
  }
}
