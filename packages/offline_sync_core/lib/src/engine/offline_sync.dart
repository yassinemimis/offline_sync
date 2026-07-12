import '../contracts/sync_adapter.dart';

/// Public entry point of the library.
///
/// Phase 0 goal: freeze this API surface so `database`, `queue`, `network`
/// and `sync` modules can all be built against a stable contract.
/// Method bodies are intentionally `UnimplementedError` here — the real
/// logic lands in Phase 1 (see roadmap).
///
/// Target developer experience:
/// ```dart
/// await OfflineSync.initialize();
/// OfflineSync.register<User>(userAdapter);
/// await OfflineSync.save<User>(user);
/// await OfflineSync.sync();
/// ```
class OfflineSync {
  OfflineSync._();

  static bool _initialized = false;
  static final Map<Type, SyncAdapter> _adapters = {};

  /// Sets up local storage, opens the queue table, and starts listening for
  /// connectivity changes. Must be called once before any other method.
  static Future<void> initialize() async {
    // Phase 1: open the storage engine (see `offline_sync_drift`),
    // run migrations, start the connectivity listener.
    throw UnimplementedError('OfflineSync.initialize — Phase 1');
  }

  /// Registers a [SyncAdapter] for type [T]. Must be called once per model
  /// before saving/reading instances of that type.
  static void register<T>(SyncAdapter<T> adapter) {
    _adapters[T] = adapter;
  }

  /// Saves [entity] to local storage immediately and enqueues a
  /// create/update operation. Returns as soon as the *local* write
  /// succeeds — network sync happens separately/asynchronously.
  static Future<void> save<T>(T entity) async {
    _requireAdapter<T>();
    // Phase 1: serialize -> write to local DB -> push SyncOperation.
    throw UnimplementedError('OfflineSync.save — Phase 1');
  }

  /// Soft-deletes the entity with [id] locally and enqueues a delete
  /// operation.
  static Future<void> delete<T>(String id) async {
    _requireAdapter<T>();
    throw UnimplementedError('OfflineSync.delete — Phase 1');
  }

  /// Reads all locally stored, non-deleted instances of [T].
  static Future<List<T>> getAll<T>() async {
    _requireAdapter<T>();
    throw UnimplementedError('OfflineSync.getAll — Phase 1');
  }

  /// Drains the queue: sends pending operations to the server in order.
  /// Safe to call manually; also triggered automatically when connectivity
  /// is restored (once `network` module lands).
  static Future<void> sync() async {
    if (!_initialized) {
      throw StateError('Call OfflineSync.initialize() first.');
    }
    // Phase 1 (happy path only): read queue -> send -> remove on success.
    // Phase 2 adds retry/backoff + conflict resolution here.
    throw UnimplementedError('OfflineSync.sync — Phase 1');
  }

  static void _requireAdapter<T>() {
    if (!_adapters.containsKey(T)) {
      throw StateError(
        'No SyncAdapter registered for type $T. '
        'Call OfflineSync.register<$T>(adapter) first.',
      );
    }
  }
}
