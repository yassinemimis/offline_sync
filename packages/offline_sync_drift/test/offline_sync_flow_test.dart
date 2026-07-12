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

    await OfflineSync.initialize(storage: storage);
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
}
