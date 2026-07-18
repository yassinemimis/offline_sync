import '../contracts/sync_adapter.dart';

/// Tracks every registered [SyncAdapter], indexed two ways: by Dart
/// [Type] (what `save<T>()`/`getAll<T>()` need) and by
/// [SyncAdapter.entityName] (all [SyncRunner] has — a queued operation
/// carries a string, not a compile-time Dart type).
class AdapterRegistry {
  final Map<Type, SyncAdapter> _byType = {};
  final Map<String, SyncAdapter> _byName = {};

  void register<T>(SyncAdapter<T> adapter) {
    _byType[T] = adapter;
    _byName[adapter.entityName] = adapter;
  }

  SyncAdapter<T> require<T>() {
    final adapter = _byType[T];
    if (adapter == null) {
      throw StateError(
        'No SyncAdapter registered for type $T. '
        'Call OfflineSync.register<$T>(adapter) first.',
      );
    }
    return adapter as SyncAdapter<T>;
  }

  SyncAdapter? byEntityName(String entityName) => _byName[entityName];

  /// Every registered adapter — used by `OfflineSync.sync()` to pull
  /// changes for all entity types in one pass, not just push the queue.
  Iterable<SyncAdapter> get all => _byName.values;
}