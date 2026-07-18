import 'dart:async';

import 'package:uuid/uuid.dart';

import '../conflict/conflict_resolver.dart';
import '../connectivity/connectivity_checker.dart';
import '../connectivity/connectivity_plus_checker.dart';
import '../contracts/delta_sync_transport.dart';
import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';
import '../retry/retry_policy.dart';
import 'adapter_registry.dart';
import 'auto_sync_controller.dart';
import 'conflict_handler.dart';
import 'delta_puller.dart';
import 'sync_runner.dart';

/// Public entry point of the library — a thin static facade. The actual
/// work is split across single-purpose collaborators:
///
/// - [AdapterRegistry] — which [SyncAdapter] belongs to which type/name.
/// - [SyncRunner] — drains the queue: send, retry/backoff, de-duplication.
/// - [ConflictHandler] — what to do with a [SyncTransportResult.conflict],
///   whether discovered via push (409) or pull.
/// - [AutoSyncController] — connectivity listening (Phase 5).
/// - [DeltaPuller] — fetches and reconciles server-side changes (Phase 7).
///
/// ```dart
/// await OfflineSync.initialize(
///   storage: DriftLocalStorage(),
///   transport: DioSyncTransport(Dio(BaseOptions(baseUrl: 'https://api.example.com'))),
/// );
/// OfflineSync.register<User>(userAdapter);
/// await OfflineSync.save(user);
/// await OfflineSync.sync();
/// await OfflineSync.pull<User>(); // explicit — see pull() docs
/// ```
class OfflineSync {
  OfflineSync._();

  static const _uuid = Uuid();

  static bool _initialized = false;
  static LocalStorage? _storage;
  static SyncTransport? _transport;
  static final AdapterRegistry _adapters = AdapterRegistry();
  static SyncRunner? _syncRunner;
  static DeltaPuller? _deltaPuller;
  static AutoSyncController? _autoSyncController;

  /// [transport] is optional: apps that only need local persistence
  /// (`save`/`getAll`, no server yet) can omit it — [sync], [pull], and
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
    _transport = transport;
    await storage.init();

    if (transport != null) {
      final conflictHandler = ConflictHandler(
        resolver: conflictResolver,
        onConflict: onConflict,
      );

      _syncRunner = SyncRunner(
        storage: storage,
        transport: transport,
        retryPolicy: retryPolicy,
        adapters: _adapters,
        conflictHandler: conflictHandler,
      );

      _deltaPuller = DeltaPuller(
        storage: storage,
        adapters: _adapters,
        conflictHandler: conflictHandler,
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
      type: existing == null
          ? SyncOperationType.create
          : SyncOperationType.update,
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

  /// Drains the queue (push — see [SyncRunner]), then fetches and
  /// reconciles server-side changes (pull — see [DeltaPuller]) for every
  /// registered entity type whose transport supports
  /// [DeltaSyncTransport]. Push always runs first, so any locally queued
  /// change gets its own chance to reach the server (and resolve a
  /// conflict via the normal 409 path) before pull independently checks
  /// the same entity.
  ///
  /// A pull failure for one entity type (network blip, bad response
  /// shape) doesn't stop the others, or hide that push already
  /// completed — it's silently skipped and retried on the next `sync()`
  /// call, same philosophy as [SyncRunner]'s per-operation error
  /// handling.
  ///
  /// KNOWN EDGE CASE: if push resolves a conflict this same call (and
  /// the resolution re-enqueues an operation — see [ConflictHandler]),
  /// the pull phase immediately after may see that same entity as
  /// "changed" again and run conflict resolution on it a second time.
  /// Not yet guarded against — flagged for a follow-up, not blocking
  /// initial testing.
  ///
  /// Call [pull] directly instead of [sync] if you want to pull one
  /// entity type without also draining the push queue.
static Future<void> sync() async {
    await _requireSyncRunner().run();

    final puller = _deltaPuller;
    final transport = _transport;

    if (puller == null || transport is! DeltaSyncTransport) return;

    final deltaTransport = transport as DeltaSyncTransport;

    for (final adapter in _adapters.all) {
      try {
        await puller.pull(adapter.entityName, deltaTransport);
      } catch (_) {
        // See doc comment above sync() — one entity's pull failure
        // shouldn't block the others or the push phase that already ran.
      }
    }
  }

  /// Fetches server-side changes for [T] since the last successful pull
  /// and reconciles them locally — see [DeltaPuller]. An unsynced local
  /// change competing with a pulled record is resolved by the same
  /// [ConflictResolver] configured at [initialize].
  ///
  /// Deliberately explicit/opt-in rather than run automatically alongside
  /// [sync] or auto-sync — pulling is a separate network call the
  /// developer should choose when to make (e.g. on screen load, pull-to-
  /// refresh), not one triggered implicitly on their behalf.
  ///
  /// Throws a [StateError] if no transport was provided at [initialize],
  /// or if it doesn't implement [DeltaSyncTransport].
  static Future<void> pull<T>() async {
    final adapter = _adapters.require<T>();
    final puller = _requireDeltaPuller();
    final transport = _requireDeltaTransport();
    await puller.pull(adapter.entityName, transport);
  }

  static Future<int> pendingOperationsCount() async {
    final storage = _requireStorage();
    return (await storage.getPendingOperations()).length;
  }

  /// Total unsynced operations, including ones currently waiting out a
  /// retry backoff window. Use this for UI ("3 changes pending"); use
  /// [pendingOperationsCount] only if you specifically need "eligible to
  /// send right now" (rarely what a UI wants).
  static Future<int> totalQueuedOperationsCount() async {
    final storage = _requireStorage();
    return storage.totalQueuedOperationsCount();
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

  static DeltaPuller _requireDeltaPuller() {
    final puller = _deltaPuller;
    if (!_initialized || puller == null) {
      throw StateError(
        'pull() requires a transport. Call OfflineSync.initialize('
        'storage: ..., transport: ...) with one.',
      );
    }
    return puller;
  }

  static DeltaSyncTransport _requireDeltaTransport() {
  final transport = _transport;

  if (transport is! DeltaSyncTransport) {
    throw StateError(
      'pull() requires a transport implementing DeltaSyncTransport, but '
      '${transport.runtimeType} does not. See DeltaSyncTransport docs.',
    );
  }

  return transport as DeltaSyncTransport;
}

  /// Cancels the connectivity subscription. Call this in tests
  /// (`tearDown`) to avoid leaked stream subscriptions across test
  /// cases, since `OfflineSync` is a static singleton and state
  /// otherwise leaks between tests in the same process.
  static Future<void> dispose() async {
    await _autoSyncController?.stop();
    _autoSyncController = null;
  }
}