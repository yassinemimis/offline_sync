import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';

/// A tiny plain Dart model — deliberately NOT extending anything from the
/// library, to prove the adapter pattern (ARCHITECTURE.md decision #2)
/// works with an ordinary class.
class User {
  User({required this.id, required this.name, required this.updatedAt});

  final String id;
  final String name;
  final DateTime updatedAt;
}

final userAdapter = SyncAdapter<User>(
  entityName: 'User',
  endpoint: '/api/users',
  fromJson: (json) => User(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  ),
  toJson: (user) => {
    'id': user.id,
    'name': user.name,
    'updatedAt': user.updatedAt.toIso8601String(),
  },
  getId: (user) => user.id,
  getUpdatedAt: (user) => user.updatedAt,
);

void main() {
  // These tests exercise the local queue/retry loop directly, not
  // connectivity — Drift intentionally opens a fresh in-memory AppDatabase
  // per test for isolation, which otherwise trips Drift's
  // "opened multiple times" heuristic (meant to catch *accidental*
  // duplicate opens of the same on-disk file, not this).
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // OfflineSync is a static singleton; cancel any leftover subscription
  // between tests so state doesn't leak across test cases.
  tearDown(() => OfflineSync.dispose());

  test('save -> stored locally + queued -> sync drains the queue', () async {
    // In-memory DB: no filesystem, no device needed — runs anywhere.
    final db = AppDatabase.withExecutor(NativeDatabase.memory());
    final storage = DriftLocalStorage(db);

    await OfflineSync.initialize(
      storage: storage,
      transport: const NoopSyncTransport(),
      // Not testing connectivity here — and ConnectivityPlusChecker needs
      // a real platform channel, unavailable in this test environment.
      autoSync: false,
    );
    OfflineSync.register<User>(userAdapter);

    final user = User(id: 'u1', name: 'Yassine', updatedAt: DateTime.now());

    // 1. Save while "offline" — must not throw, must not need network.
    await OfflineSync.save(user);

    // 2. It's readable back locally immediately.
    final all = await OfflineSync.getAll<User>();
    expect(all, hasLength(1));
    expect(all.first.name, 'Yassine');

    // 3. It produced exactly one pending queue operation.
    final pendingBefore = await storage.getPendingOperations();
    expect(pendingBefore, hasLength(1));
    expect(pendingBefore.first.type, SyncOperationType.create);

    // 4. sync() drains it.
    await OfflineSync.sync();
    final pendingAfter = await storage.getPendingOperations();
    expect(pendingAfter, isEmpty);

    // 5. The entity itself is still there — sync clears the queue, not
    // the data.
    final stillThere = await OfflineSync.getAll<User>();
    expect(stillThere, hasLength(1));
  });

  test('sync() keeps a failed operation queued, marked failed, retry bumped',
      () async {
    final db = AppDatabase.withExecutor(NativeDatabase.memory());
    final storage = DriftLocalStorage(db);
    final beforeCall = DateTime.now();

    await OfflineSync.initialize(
      storage: storage,
      transport: const _AlwaysFailsTransport(),
      autoSync: false,
    );
    OfflineSync.register<User>(userAdapter);

    await OfflineSync.save(
      User(id: 'u2', name: 'Fatima', updatedAt: DateTime.now()),
    );

    await OfflineSync.sync();

    final pendingRightNow = await storage.getPendingOperations();
    expect(pendingRightNow, isEmpty,
        reason: 'backoff should hide it until nextRetryAt passes');

    final scheduled = await storage.getPendingOperations(
      now: beforeCall.add(const Duration(days: 1)),
    );
    expect(scheduled, hasLength(1),
        reason: 'a failed send must not be removed from the queue');
    expect(scheduled.first.status, SyncOperationStatus.failed);
    expect(scheduled.first.retryCount, 1);
    expect(scheduled.first.nextRetryAt, isNotNull);
    expect(
      scheduled.first.nextRetryAt!.isAfter(beforeCall),
      isTrue,
      reason: 'RetryPolicy.baseDelay should push the next attempt out',
    );
  });

  test('sync() marks an operation exhausted once retries run out', () async {
    final db = AppDatabase.withExecutor(NativeDatabase.memory());
    final storage = DriftLocalStorage(db);

    await OfflineSync.initialize(
      storage: storage,
      transport: const _AlwaysFailsTransport(),
      retryPolicy: const RetryPolicy(
        baseDelay: Duration(microseconds: 1),
        maxAttempts: 2,
      ),
      autoSync: false,
    );
    OfflineSync.register<User>(userAdapter);

    await OfflineSync.save(
      User(id: 'u3', name: 'Karim', updatedAt: DateTime.now()),
    );

    await OfflineSync.sync();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await OfflineSync.sync();

    final farFuture = await storage.getPendingOperations(
      now: DateTime.now().add(const Duration(days: 1)),
    );
    expect(farFuture, isEmpty,
        reason: 'exhausted operations must never be returned again');
  });

  test('sync() sends a non-retriable failure straight to exhausted',
      () async {
    final db = AppDatabase.withExecutor(NativeDatabase.memory());
    final storage = DriftLocalStorage(db);

    await OfflineSync.initialize(
      storage: storage,
      transport: const _AlwaysRejectsTransport(),
      autoSync: false,
    );
    OfflineSync.register<User>(userAdapter);

    await OfflineSync.save(
      User(id: 'u4', name: 'Sara', updatedAt: DateTime.now()),
    );

    await OfflineSync.sync();

    final farFuture = await storage.getPendingOperations(
      now: DateTime.now().add(const Duration(days: 1)),
    );
    expect(farFuture, isEmpty,
        reason: 'a non-retriable (e.g. 4xx-style) failure skips backoff '
            'entirely and goes straight to exhausted');
  });
}

class _AlwaysFailsTransport implements SyncTransport {
  const _AlwaysFailsTransport();

  @override
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  ) async {
    return const SyncTransportResult.failure(retriable: true);
  }
}

class _AlwaysRejectsTransport implements SyncTransport {
  const _AlwaysRejectsTransport();

  @override
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  ) async {
    return const SyncTransportResult.failure(retriable: false);
  }
}