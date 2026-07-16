import 'package:uuid/uuid.dart';

import '../conflict/conflict_resolver.dart';
import '../connectivity/connectivity_checker.dart';
import '../connectivity/connectivity_plus_checker.dart';
import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';
import '../retry/retry_policy.dart';
import 'adapter_registry.dart';
import 'auto_sync_controller.dart';
import 'conflict_handler.dart';
import 'sync_runner.dart';
import 'dart:async';
/// Public entry point of the library — a thin static facade. The actual
/// work is split across single-purpose collaborators:
///
/// - [AdapterRegistry] — which [SyncAdapter] belongs to which type/name.
/// - [SyncRunner] — drains the queue: send, retry/backoff, de-duplication.
/// - [ConflictHandler] — what to do with a [SyncTransportResult.conflict].
/// - [AutoSyncController] — connectivity listening (Phase 5).
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
  static final AdapterRegistry _adapters = AdapterRegistry();
  static SyncRunner? _syncRunner;
  static AutoSyncController? _autoSyncController;

  /// [transport] is optional: apps that only need local persistence
  /// (`save`/`getAll`, no server yet) can omit it — [sync] and
  /// [pendingOperationsCount] will throw a clear error if called without
  /// one. [autoSync] (default `true`) starts [AutoSyncController]
  /// automatically once a [transport] is provided.
  static Future<void> initialize({
    required LocalStorage storage,
    SyncTransport? transport,
    RetryPolicy retryPolicy = const RetryPolicy(),
    ConflictResolver conflictResolver = const ConflictResolver.lastWriteWins(),
    void Function(SyncConflict conflict, Map<String, dynamic> winningData)?
        onConflict,
    ConnectivityChecker connectivityChecker = const ConnectivityPlusChecker(),
    bool autoSync = true,
  }) async {
    _storage = storage;
    await storage.init();

    if (transport != null) {
      _syncRunner = SyncRunner(
        storage: storage,
        transport: transport,
        retryPolicy: retryPolicy,
        adapters: _adapters,
        conflictHandler: ConflictHandler(
          resolver: conflictResolver,
          onConflict: onConflict,
        ),
      );
    }

    _initialized = true;

    if (autoSync && _syncRunner != null) {
      _autoSyncController = AutoSyncController(connectivityChecker);
      await _autoSyncController!.start(sync);
    }
  }

  static void register<T>(SyncAdapter<T> adapter) =>
      _adapters.register<T>(adapter);

  static Future<void> save<T>(T entity) async {
    final adapter = _adapters.require<T>();
    final storage = _requireStorage();

    final id = adapter.getId(entity);
    final updatedAt = adapter.getUpdatedAt(entity);
    final json = adapter.toJson(entity);

    final existing =
        await storage.getEntity(entityName: adapter.entityName, entityId: id);

    final baselineVersion = await storage.saveEntity(
      entityName: adapter.entityName,
      entityId: id,
      data: json,
      updatedAt: updatedAt,
    );

    await storage.enqueueOperation(SyncOperation(
  id: _uuid.v4(),
  entityName: adapter.entityName,
  entityId: id,
  type: existing == null ? SyncOperationType.create : SyncOperationType.update,
  payload: json,
  createdAt: DateTime.now(),
  localVersion: baselineVersion,
));

// Opportunistic sync: try to push immediately if a transport is
// configured. Doesn't matter whether the device was "already online"
// or just reconnected — either way, don't make the user wait for a
// connectivity *change* event that may never fire. Fire-and-forget:
// failures are handled by SyncRunner's own retry/backoff, same as any
// other sync attempt.
unawaited(_syncRunner?.run());
  }

  static Future<void> delete<T>(String id) async {
    final adapter = _adapters.require<T>();
    final storage = _requireStorage();

    final baselineVersion = await storage.softDeleteEntity(
      entityName: adapter.entityName,
      entityId: id,
    );

    await storage.enqueueOperation(SyncOperation(
  id: _uuid.v4(),
  entityName: adapter.entityName,
  entityId: id,
  type: SyncOperationType.delete,
  payload: const {},
  createdAt: DateTime.now(),
  localVersion: baselineVersion,
));

unawaited(_syncRunner?.run());
  }

  static Future<List<T>> getAll<T>() async {
    final adapter = _adapters.require<T>();
    final storage = _requireStorage();
    final rows = await storage.getAllEntities(adapter.entityName);
    return rows.map(adapter.fromJson).toList();
  }

  /// Drains the queue — see [SyncRunner] for full behavior (retry/
  /// backoff, conflict handling, de-duplication of concurrent calls).
  static Future<void> sync() => _requireSyncRunner().run();

  static Future<int> pendingOperationsCount() async {
    final storage = _requireStorage();
    return (await storage.getPendingOperations()).length;
  }

  static LocalStorage _requireStorage() {
    if (!_initialized || _storage == null) {
      throw StateError('Call OfflineSync.initialize(storage: ...) first.');
    }
    return _storage!;
  }

  static SyncRunner _requireSyncRunner() {
    final runner = _syncRunner;
    if (!_initialized || runner == null) {
      throw StateError(
        'sync() requires a transport. Call OfflineSync.initialize('
        'storage: ..., transport: ...) with one.',
      );
    }
    return runner;
  }

  /// Cancels the connectivity subscription. Call this in tests
  /// (`tearDown`) to avoid leaked stream subscriptions across test
  /// cases, since `OfflineSync` is a static singleton and state
  /// otherwise leaks between tests in the same process.
  static Future<void> dispose() async {
    await _autoSyncController?.stop();
    _autoSyncController = null;
  }
  /// Total unsynced operations, including ones currently waiting out a
/// retry backoff window. Use this for UI ("3 changes pending"); use
/// [pendingOperationsCount] only if you specifically need "eligible to
/// send right now" (rarely what a UI wants).
static Future<int> totalQueuedOperationsCount() async {
  final storage = _requireStorage();
  return storage.totalQueuedOperationsCount();
}
}