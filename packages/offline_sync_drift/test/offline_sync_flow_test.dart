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
  test('save -> stored locally + queued -> sync drains the queue', () async {
    // In-memory DB: no filesystem, no device needed — runs anywhere.
    final db = AppDatabase.withExecutor(NativeDatabase.memory());
    final storage = DriftLocalStorage(db);

    await OfflineSync.initialize(
      storage: storage,
      transport: const NoopSyncTransport(),
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
    );
    OfflineSync.register<User>(userAdapter);

    await OfflineSync.save(
      User(id: 'u2', name: 'Fatima', updatedAt: DateTime.now()),
    );

    await OfflineSync.sync();

    // getPendingOperations(now: ...) defaults to "right now" if omitted,
    // and this op's nextRetryAt is ~5s in the future (default
    // RetryPolicy.baseDelay), so it correctly won't show up yet.
    final pendingRightNow = await storage.getPendingOperations();
    expect(pendingRightNow, isEmpty,
        reason: 'backoff should hide it until nextRetryAt passes');

    // Query without the time filter (pass a far-future "now") to inspect
    // the row itself.
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
      // Tiny delay so each failed operation becomes eligible again almost
      // immediately -- lets the test call sync() repeatedly without
      // actually waiting minutes for real backoff timers.
      retryPolicy: const RetryPolicy(
        baseDelay: Duration(microseconds: 1),
        maxAttempts: 2,
      ),
    );
    OfflineSync.register<User>(userAdapter);

    await OfflineSync.save(
      User(id: 'u3', name: 'Karim', updatedAt: DateTime.now()),
    );

    await OfflineSync.sync(); // attempt 1 -> failed, retryCount 1
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await OfflineSync.sync(); // attempt 2 -> exhausted, retryCount 2

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

/// Simulates a server/network that always rejects the request — e.g. the
/// device went offline again mid-sync, or the server returned a 5xx.
/// Retriable: eligible for backoff and another attempt.
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

/// Simulates a server that actively rejects the request (e.g. a 422
/// validation error) — not retriable, since resending identical bytes
/// won't change the outcome.
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
