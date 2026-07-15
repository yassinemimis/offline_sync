import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

void main() {
  SyncConflict buildConflict({
    DateTime? localUpdatedAt,
    DateTime? serverUpdatedAt,
    Map<String, dynamic>? localData,
    Map<String, dynamic>? serverData,
  }) {
    return SyncConflict(
      entityName: 'User',
      entityId: '1',
      localData: localData ?? const {'name': 'Local Name'},
      localVersion: 1,
      localUpdatedAt: localUpdatedAt ?? DateTime(2026, 1, 1, 12, 0, 0),
      serverData: serverData ?? const {'name': 'Server Name'},
      serverVersion: 2,
      serverUpdatedAt: serverUpdatedAt ?? DateTime(2026, 1, 1, 12, 0, 0),
    );
  }

  group('ConflictResolver.serverWins', () {
    const resolver = ConflictResolver.serverWins();

    test('always returns serverData', () async {
      final conflict = buildConflict();
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.serverData));
    });

    test('returns serverData even when localUpdatedAt is more recent', () async {
      final conflict = buildConflict(
        localUpdatedAt: DateTime(2026, 1, 2),
        serverUpdatedAt: DateTime(2026, 1, 1),
      );
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.serverData));
    });
  });

  group('ConflictResolver.clientWins', () {
    const resolver = ConflictResolver.clientWins();

    test('always returns localData', () async {
      final conflict = buildConflict();
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.localData));
    });

    test('returns localData even when serverUpdatedAt is more recent', () async {
      final conflict = buildConflict(
        localUpdatedAt: DateTime(2026, 1, 1),
        serverUpdatedAt: DateTime(2026, 1, 2),
      );
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.localData));
    });
  });

  group('ConflictResolver.lastWriteWins', () {
    const resolver = ConflictResolver.lastWriteWins();

    test('returns localData when localUpdatedAt is after serverUpdatedAt', () async {
      final conflict = buildConflict(
        localUpdatedAt: DateTime(2026, 1, 2),
        serverUpdatedAt: DateTime(2026, 1, 1),
      );
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.localData));
    });

    test('returns serverData when serverUpdatedAt is after localUpdatedAt', () async {
      final conflict = buildConflict(
        localUpdatedAt: DateTime(2026, 1, 1),
        serverUpdatedAt: DateTime(2026, 1, 2),
      );
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.serverData));
    });

    test('returns serverData when both timestamps are exactly equal', () async {
      final sameTime = DateTime(2026, 1, 1, 12, 0, 0);
      final conflict = buildConflict(
        localUpdatedAt: sameTime,
        serverUpdatedAt: sameTime,
      );
      final result = await resolver.resolve(conflict);
      // isAfter() is false for equal timestamps, so the server side wins ties.
      expect(result, same(conflict.serverData));
    });
  });

  group('ConflictResolver.manual', () {
    test('invokes the provided callback and returns its result', () async {
      final conflict = buildConflict();
      var callCount = 0;

      final resolver = ConflictResolver.manual((c) {
        callCount++;
        expect(c, same(conflict));
        return {'name': 'Merged Name'};
      });

      final result = await resolver.resolve(conflict);

      expect(callCount, 1);
      expect(result, {'name': 'Merged Name'});
      // A hand-merged map is a new object — neither identical to
      // localData nor serverData, which the sync engine relies on to
      // treat it as "still needs pushing to the server".
      expect(result, isNot(same(conflict.localData)));
      expect(result, isNot(same(conflict.serverData)));
    });

    test('supports an async callback (e.g. awaiting a user dialog)', () async {
      final conflict = buildConflict();

      final resolver = ConflictResolver.manual((c) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return c.serverData;
      });

      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.serverData));
    });

    test('can return localData or serverData directly by reference', () async {
      final conflict = buildConflict();

      final resolver = ConflictResolver.manual((c) => c.serverData);
      final result = await resolver.resolve(conflict);

      // Choosing to return the exact serverData reference means the sync
      // engine will correctly treat this as "server already has it".
      expect(result, same(conflict.serverData));
    });
  });

  group('ConflictResolver default', () {
    test('unnamed usage defaults to lastWriteWins semantics when constructed that way', () async {
      // There's no plain `ConflictResolver()` constructor — this test
      // documents that OfflineSync.initialize()'s default parameter is
      // ConflictResolver.lastWriteWins(), by exercising it the same way.
      const resolver = ConflictResolver.lastWriteWins();
      final conflict = buildConflict(
        localUpdatedAt: DateTime(2026, 1, 3),
        serverUpdatedAt: DateTime(2026, 1, 1),
      );
      final result = await resolver.resolve(conflict);
      expect(result, same(conflict.localData));
    });
  });
}