# offline_sync_core

Storage-agnostic core of the [Flutter Offline Sync Kit](https://github.com/<org>/offline_sync).
Defines the public `OfflineSync` API, the `SyncAdapter` contract, and the
`LocalStorage` interface that database packages (like
[`offline_sync_drift`](../offline_sync_drift)) implement.

This package has **no database and no HTTP client dependency**. It doesn't
know how your data is stored or sent — it only orchestrates *when* those
things happen.

## Install

```yaml
dependencies:
  offline_sync_core: ^0.0.1
  offline_sync_drift: ^0.0.1 # or another storage adapter
```

## Quick start

```dart
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';

class User {
  User({required this.id, required this.name, required this.updatedAt});
  final String id;
  final String name;
  final DateTime updatedAt;
}

final userAdapter = SyncAdapter<User>(
  entityName: 'User',
  endpoint: '/api/users',
  toJson: (u) => {'id': u.id, 'name': u.name, 'updatedAt': u.updatedAt.toIso8601String()},
  fromJson: (json) => User(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  ),
  getId: (u) => u.id,
  getUpdatedAt: (u) => u.updatedAt,
);

Future<void> main() async {
  await OfflineSync.initialize(storage: DriftLocalStorage());
  OfflineSync.register<User>(userAdapter);

  await OfflineSync.save(User(id: '1', name: 'Ahmed', updatedAt: DateTime.now()));
  final users = await OfflineSync.getAll<User>(); // reads from local storage
  await OfflineSync.sync();                        // drains the queue
}
```

## Core concepts

### `SyncAdapter<T>` — how the engine learns about your model

Instead of forcing your models to `extends Syncable` or implement an
interface, you hand the engine a small set of functions that describe the
*shape* of `T`. This works with plain classes, `freezed`, `equatable`,
`json_serializable` — anything.

| Field | Purpose |
|---|---|
| `entityName` | Stable name used as the storage table / queue tag (e.g. `"User"`). Must be unique per registration. |
| `toJson` / `fromJson` | Serialize for local storage and the outgoing queue payload. |
| `getId` | Unique id of an entity. Always a `String` — generate a UUID client-side so records can be created fully offline. |
| `getUpdatedAt` | Last-modified timestamp. Used by the default conflict strategy and delta sync. |
| `endpoint` | Base REST endpoint for this entity, e.g. `/api/users`. |
| `isDeleted` *(optional)* | Lets the adapter read a soft-delete flag off `T` itself. |

### `save()` never touches the network

```dart
await OfflineSync.save(user);
```

does two things, synchronously with each other but never with a server:

1. Writes the entity to local storage immediately (upsert).
2. Enqueues a `create` or `update` `SyncOperation` — the engine reads the
   existing row first to know which one.

It returns as soon as the *local* write succeeds. This is the whole point:
the UI never has to wait for, or care about, connectivity.

### The queue, not the data

Each `SyncOperation` records an *intent* (`create` / `update` / `delete`),
not just a data snapshot. This matters for deletes in particular — if we
only synced the database contents, a locally-deleted row would simply
disappear from view, and the server would never learn it should be
deleted. The queue is what tells the server *what happened*, in order.

### Soft delete

`delete<T>(id)` never removes a row immediately. It sets `deleted = true`
locally and enqueues a `delete` operation. The row is hidden from
`getAll<T>()` but still physically present until the delete operation is
confirmed against the server — see `LocalStorage.hardDeleteEntity`.

### `sync()` — status today

`sync()` reads all pending operations and drains the queue. **As of Phase
1, this only happens locally** — there is no HTTP transport yet, so
`sync()` proves the local write → queue → drain loop works, but does not
talk to a server. That lands with the network module (Phase 2); see the
[project roadmap](../../README.md#roadmap).

## Implementing your own storage adapter

`offline_sync_drift` is the reference implementation, but any package can
provide local storage by implementing `LocalStorage`:

```dart
abstract class LocalStorage {
  Future<void> init();

  Future<void> saveEntity({required String entityName, required String entityId, required Map<String, dynamic> data, required DateTime updatedAt});
  Future<void> softDeleteEntity({required String entityName, required String entityId});
  Future<void> hardDeleteEntity({required String entityName, required String entityId});
  Future<Map<String, dynamic>?> getEntity({required String entityName, required String entityId});
  Future<List<Map<String, dynamic>>> getAllEntities(String entityName);

  Future<void> enqueueOperation(SyncOperation operation);
  Future<List<SyncOperation>> getPendingOperations();
  Future<void> updateOperationStatus(String operationId, SyncOperationStatus status, {int? retryCount});
  Future<void> removeOperation(String operationId);
}
```

See [`ARCHITECTURE.md`](../../ARCHITECTURE.md) for why the adapter pattern
was chosen over inheritance, and why storage packages are split from
`core` in the first place.

## License

MIT (proposed — confirm before first public release).