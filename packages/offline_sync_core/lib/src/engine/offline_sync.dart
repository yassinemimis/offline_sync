import 'package:uuid/uuid.dart';

import '../contracts/local_storage.dart';
import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';
import '../retry/retry_policy.dart';
import '../conflict/conflict_resolver.dart';

/// Public entry point of the library.
///
/// Phase 3 status: `register`, `save`, `delete`, `getAll` are fully
/// implemented against [LocalStorage]. `sync()` sends queued operations
/// through a [SyncTransport] and now applies exponential backoff
/// ([RetryPolicy]) on retriable failures. Conflict resolution (Phase 4)
/// is still open.
///
/// ```dart
/// await OfflineSync.initialize(
///   storage: DriftLocalStorage(),
///   transport: DioSyncTransport(Dio(BaseOptions(baseUrl: 'https://api.example.com'))),
///   retryPolicy: const RetryPolicy(maxAttempts: 5), // optional, has a default
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
  static RetryPolicy _retryPolicy = const RetryPolicy();
  static final Map<Type, SyncAdapter> _adapters = {};

  /// Adapters are also keyed by [SyncAdapter.entityName] because [sync]
  /// only has that string (from the queue row) to work with — it has no
  /// Dart [Type] to look the adapter up by at that point.
  static final Map<String, SyncAdapter> _adaptersByName = {};
  static ConflictResolver _conflictResolver = const ConflictResolver.lastWriteWins();
  /// Opens local storage and runs migrations, and wires up the transport
  /// used by [sync]. Both are injected so `core` never depends on a
  /// concrete database or HTTP package directly. [retryPolicy] controls
  /// backoff timing and the retry budget; the default is reasonable for
  /// most apps — see [RetryPolicy] to tune it.
 static Future<void> initialize({
  required LocalStorage storage,
  SyncTransport? transport,
  RetryPolicy retryPolicy = const RetryPolicy(),
  ConflictResolver conflictResolver = const ConflictResolver.lastWriteWins(),
  void Function(SyncConflict conflict, Map<String, dynamic> winningData)? onConflict,
}) async {
  _storage = storage;
  _transport = transport;
  _retryPolicy = retryPolicy;
  _conflictResolver = conflictResolver;
  _onConflict = onConflict;
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

  final existing = await storage.getEntity(entityName: adapter.entityName, entityId: id);

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
}

  /// Soft-deletes the entity with [id] locally and enqueues a delete
  /// operation.
 static Future<void> delete<T>(String id) async {
  final adapter = _requireAdapter<T>();
  final storage = _requireStorage();

  final baselineVersion = await storage.softDeleteEntity(entityName: adapter.entityName, entityId: id);

  await storage.enqueueOperation(SyncOperation(
    id: _uuid.v4(),
    entityName: adapter.entityName,
    entityId: id,
    type: SyncOperationType.delete,
    payload: const {},
    createdAt: DateTime.now(),
    localVersion: baselineVersion,
  ));
}

  /// Reads all locally stored, non-deleted instances of [T].
  static Future<List<T>> getAll<T>() async {
    final adapter = _requireAdapter<T>() as SyncAdapter<T>;
    final storage = _requireStorage();

    final rows = await storage.getAllEntities(adapter.entityName);
    return rows.map(adapter.fromJson).toList();
  }

  /// Drains the queue by sending every operation that's currently
  /// eligible ([LocalStorage.getPendingOperations]) through the
  /// registered [SyncTransport], in the order they were created.
  ///
  /// - On success: the operation is removed from the queue.
  /// - On a **retriable** failure (e.g. timeout, 5xx) with attempts left
  ///   under [RetryPolicy.maxAttempts]: marked
  ///   [SyncOperationStatus.failed], `retryCount` incremented, and
  ///   [SyncOperation.nextRetryAt] pushed out per
  ///   [RetryPolicy.nextRetryAt]. It's skipped by
  ///   [LocalStorage.getPendingOperations] until that time passes — so
  ///   calling [sync] again right away is safe and simply won't resend it
  ///   yet.
  /// - On a **non-retriable** failure (e.g. 4xx), or once
  ///   [RetryPolicy.maxAttempts] is used up: marked
  ///   [SyncOperationStatus.exhausted]. No longer retried automatically.
  ///
  /// An operation whose `entityName` has no matching registered adapter
  /// is skipped for this call rather than crashing the whole sync — it's
  /// picked up again on the next [sync] call once the adapter is
  /// registered.
  static Future<void> sync() async {
  final storage = _requireStorage();
  final transport = _requireTransport();
  final now = DateTime.now();
  final pending = await storage.getPendingOperations(now: now);

  for (final op in pending) {
    final adapter = _adaptersByName[op.entityName];
    if (adapter == null) continue;

    final result = await transport.send(op, adapter);

    if (result.isSuccess) {
      if (op.type == SyncOperationType.delete) {
        await storage.hardDeleteEntity(entityName: op.entityName, entityId: op.entityId);
      } else {
        await storage.markSynced(entityName: op.entityName, entityId: op.entityId);
      }
      await storage.removeOperation(op.id);
      continue;
    }

    if (result.isConflict) {
      await _resolveConflict(op, adapter, result, storage);
      continue;
    }

    // فشل عادي — نفس منطق retry/backoff اللي عندك أصلاً (RetryPolicy)
    final newRetryCount = op.retryCount + 1;
    final canRetry = result.retriable && _retryPolicy.hasAttemptsLeft(newRetryCount);
    if (canRetry) {
      await storage.updateOperationStatus(
        op.id,
        SyncOperationStatus.failed,
        retryCount: newRetryCount,
        nextRetryAt: _retryPolicy.nextRetryAt(newRetryCount, now: now),
      );
    } else {
      await storage.updateOperationStatus(op.id, SyncOperationStatus.exhausted, retryCount: newRetryCount);
    }
  }
}

static Future<void> _resolveConflict(
  SyncOperation op,
  SyncAdapter adapter,
  SyncTransportResult result,
  LocalStorage storage,
) async {
  final localEntity = adapter.fromJson(op.payload);
  final serverEntity = adapter.fromJson(result.serverData!);

  final conflict = SyncConflict(
    entityName: op.entityName,
    entityId: op.entityId,
    localData: op.payload,
    localVersion: op.localVersion,
    localUpdatedAt: adapter.getUpdatedAt(localEntity),
    serverData: result.serverData!,
    serverVersion: result.serverVersion!,
    serverUpdatedAt: adapter.getUpdatedAt(serverEntity),
  );

  final winningData = await _conflictResolver.resolve(conflict);
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
    // المحتوى الرابح لسا ما وصل السيرفر — نعيد جدولته بـ baseline محدّث
    // (نسخة السيرفر الحالية)، عشان محاولة الإرسال الجاية تنجح.
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
  static void Function(SyncConflict conflict, Map<String, dynamic> winningData)? _onConflict;
  static Future<int> pendingOperationsCount() async {
  final storage = _requireStorage();
  return (await storage.getPendingOperations()).length;
}
}
