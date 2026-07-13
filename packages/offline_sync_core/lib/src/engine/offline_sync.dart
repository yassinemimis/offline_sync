import 'package:uuid/uuid.dart';

import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';

/// Public entry point of the library.
///
/// Phase 2 status: `register`, `save`, `delete`, `getAll` are fully
/// implemented against [LocalStorage]. `sync()` now actually sends queued
/// operations through a [SyncTransport] (e.g. `DioSyncTransport` from
/// `offline_sync_dio`) — retry/backoff (Phase 3) and conflict resolution
/// (Phase 4) are still open.
///
/// ```dart
/// await OfflineSync.initialize(
///   storage: DriftLocalStorage(),
///   transport: DioSyncTransport(Dio(BaseOptions(baseUrl: 'https://api.example.com'))),
/// );
/// OfflineSync.register<User>(userAdapter);
/// await OfflineSync.save(user);
/// await OfflineSync.sync();
/// ```
class OfflineSync {
  OfflineSync._();

  static const _uuid = Uuid();

  static bool _initialized = false;
  static LocalStorage? _storage;
  static SyncTransport? _transport;
  static final Map<Type, SyncAdapter> _adapters = {};

  /// Adapters are also keyed by [SyncAdapter.entityName] because [sync]
  /// only has that string (from the queue row) to work with — it has no
  /// Dart [Type] to look the adapter up by at that point.
  static final Map<String, SyncAdapter> _adaptersByName = {};

  /// Opens local storage and runs migrations, and wires up the transport
  /// used by [sync]. Both are injected so `core` never depends on a
  /// concrete database or HTTP package directly.
  static Future<void> initialize({
    required LocalStorage storage,
    required SyncTransport transport,
  }) async {
    _storage = storage;
    _transport = transport;
    await storage.init();
    _initialized = true;
  }

  /// Registers a [SyncAdapter] for type [T]. Must be called once per model
  /// before saving/reading instances of that type.
  static void register<T>(SyncAdapter<T> adapter) {
    _adapters[T] = adapter;
    _adaptersByName[adapter.entityName] = adapter;
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

  /// Drains the queue by sending every pending/failed operation through
  /// the registered [SyncTransport], in the order they were created.
  ///
  /// - On success: the operation is removed from the queue
  ///   ([LocalStorage.removeOperation]).
  /// - On failure: the operation is marked [SyncOperationStatus.failed]
  ///   and its `retryCount` is incremented, but it stays in the queue.
  ///   Nothing is retried automatically yet — that's Phase 3
  ///   (retry/backoff). For now, calling [sync] again will simply retry
  ///   every `failed` operation immediately, since
  ///   [LocalStorage.getPendingOperations] returns both `pending` and
  ///   `failed` rows.
  ///
  /// An operation whose `entityName` has no matching registered adapter
  /// is skipped for this call rather than crashing the whole sync — it's
  /// picked up again on the next [sync] call once the adapter is
  /// registered.
  static Future<void> sync() async {
    final storage = _requireStorage();
    final transport = _requireTransport();
    final pending = await storage.getPendingOperations();

    for (final op in pending) {
      final adapter = _adaptersByName[op.entityName];
      if (adapter == null) {
        assert(
          false,
          'No SyncAdapter registered for entityName "${op.entityName}" '
          '— skipping queued operation ${op.id} for now.',
        );
        continue;
      }

      final result = await transport.send(op, adapter);

      if (result.isSuccess) {
        await storage.removeOperation(op.id);
      } else {
        await storage.updateOperationStatus(
          op.id,
          SyncOperationStatus.failed,
          retryCount: op.retryCount + 1,
        );
      }
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
        'Call OfflineSync.initialize(storage: ..., transport: ...) first.',
      );
    }
    return _storage!;
  }

  static SyncTransport _requireTransport() {
    if (!_initialized || _transport == null) {
      throw StateError(
        'Call OfflineSync.initialize(storage: ..., transport: ...) first.',
      );
    }
    return _transport!;
  }
}