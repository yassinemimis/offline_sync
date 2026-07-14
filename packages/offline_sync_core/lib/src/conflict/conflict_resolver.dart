import 'dart:async';

/// The two versions of an entity that disagree, plus enough context for a
/// [ConflictResolver] to pick a winner.
///
/// [localVersion] / [serverVersion] are the optimistic-concurrency tokens
/// (see `EntitiesTable.version`) — the mismatch between them is *why*
/// there's a conflict at all: the client tried to write based on a
/// [localVersion] baseline that no longer matches what the server has.
class SyncConflict {
  const SyncConflict({
    required this.entityName,
    required this.entityId,
    required this.localData,
    required this.localVersion,
    required this.localUpdatedAt,
    required this.serverData,
    required this.serverVersion,
    required this.serverUpdatedAt,
  });

  final String entityName;
  final String entityId;

  final Map<String, dynamic> localData;
  final int localVersion;
  final DateTime localUpdatedAt;

  final Map<String, dynamic> serverData;
  final int serverVersion;
  final DateTime serverUpdatedAt;
}

enum ConflictStrategyType { serverWins, clientWins, lastWriteWins, manual }

/// Lets a developer decide the winner by hand — e.g. show a merge dialog
/// and return whichever data the user picks, or a hand-merged map that's
/// neither exactly [SyncConflict.localData] nor [SyncConflict.serverData].
/// Only invoked when [ConflictResolver.type] is
/// [ConflictStrategyType.manual].
typedef ManualConflictResolver = FutureOr<Map<String, dynamic>> Function(
  SyncConflict conflict,
);

/// Resolves a [SyncConflict] to a single winning JSON payload.
///
/// Pass an instance to `OfflineSync.initialize(conflictResolver: ...)`.
/// Default (if none is passed) is [ConflictResolver.lastWriteWins].
class ConflictResolver {
  const ConflictResolver.serverWins() : this._(ConflictStrategyType.serverWins);
  const ConflictResolver.clientWins() : this._(ConflictStrategyType.clientWins);
  const ConflictResolver.lastWriteWins()
      : this._(ConflictStrategyType.lastWriteWins);

  /// [resolver] is called once per conflict. It's fine for it to be slow
  /// (e.g. await a dialog the user has to respond to) — `sync()` simply
  /// awaits it before moving to the next queued operation.
  const ConflictResolver.manual(ManualConflictResolver resolver)
      : this._(ConflictStrategyType.manual, resolver);

  const ConflictResolver._(this.type, [this._manualResolver]);

  final ConflictStrategyType type;
  final ManualConflictResolver? _manualResolver;

  /// Returns the winning entity data.
  ///
  /// For [ConflictStrategyType.serverWins]/[ConflictStrategyType.clientWins]/
  /// [ConflictStrategyType.lastWriteWins] this always returns *the exact
  /// same object reference* as [SyncConflict.serverData] or
  /// [SyncConflict.localData] — the sync engine relies on that (via
  /// `identical()`) to know whether the winning content still needs to be
  /// pushed to the server or not. A [ConflictStrategyType.manual] resolver
  /// that hand-merges fields into a *new* map is treated as "still needs
  /// pushing", which is correct: the server doesn't have that exact merge
  /// yet either.
  Future<Map<String, dynamic>> resolve(SyncConflict conflict) async {
    switch (type) {
      case ConflictStrategyType.serverWins:
        return conflict.serverData;
      case ConflictStrategyType.clientWins:
        return conflict.localData;
      case ConflictStrategyType.lastWriteWins:
        return conflict.localUpdatedAt.isAfter(conflict.serverUpdatedAt)
            ? conflict.localData
            : conflict.serverData;
      case ConflictStrategyType.manual:
        final resolver = _manualResolver;
        if (resolver == null) {
          throw StateError(
            'ConflictStrategyType.manual requires a resolver — use '
            'ConflictResolver.manual((conflict) => ...) instead of '
            'constructing ConflictResolver.manual with no callback.',
          );
        }
        return await resolver(conflict);
    }
  }
}