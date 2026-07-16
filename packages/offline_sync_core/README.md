# offline_sync_core

Storage-agnostic core of the [Flutter Offline Sync Kit](https://github.com/<org>/offline_sync).
Defines the public `OfflineSync` API, the `SyncAdapter` contract, the
`LocalStorage` interface implemented by database packages (like
[`offline_sync_drift`](../offline_sync_drift)), and the `SyncTransport`
interface implemented by network packages (like
[`offline_sync_dio`](../offline_sync_dio)).

This package has **no database and no HTTP client dependency**. It doesn't
know how your data is stored or sent — it only orchestrates *when* those
things happen, and what to do when a send succeeds, fails, or conflicts.

## Install

```yaml
dependencies:
  offline_sync_core: ^0.0.1
  offline_sync_drift: ^0.0.1 # or another storage adapter
  offline_sync_dio: ^0.0.1   # or another network adapter
```

## Quick start

```dart
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:dio/dio.dart';

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
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

  await OfflineSync.initialize(
    storage: DriftLocalStorage(),
    transport: DioSyncTransport(dio),
    retryPolicy: const RetryPolicy(),                       // optional, has a default
    conflictResolver: const ConflictResolver.lastWriteWins(), // optional, has a default
    onConflict: (conflict, winningData) {                    // optional
      print('Resolved conflict on ${conflict.entityName}/${conflict.entityId}');
    },
  );
  OfflineSync.register<User>(userAdapter);

  await OfflineSync.save(User(id: '1', name: 'Ahmed', updatedAt: DateTime.now()));
  final users = await OfflineSync.getAll<User>(); // reads from local storage
  await OfflineSync.sync();                        // sends the queue, retries, resolves conflicts
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
| `toJson` / `fromJson` | Serialize for local storage, the outgoing queue payload, and decoding server responses. |
| `getId` | Unique id of an entity. Always a `String` — generate a UUID client-side so records can be created fully offline. |
| `getUpdatedAt` | Last-modified timestamp. Used by the `lastWriteWins` conflict strategy. |
| `endpoint` | Base REST endpoint for this entity, e.g. `/api/users`. Interpreted by the configured `SyncTransport`. |
| `isDeleted` *(optional)* | Lets the adapter read a soft-delete flag off `T` itself. |

### `save()` never touches the network

```dart
await OfflineSync.save(user);
```

does two things, synchronously with each other but never with a server:

1. Writes the entity to local storage immediately (upsert).
2. Enqueues a `create` or `update` `SyncOperation` — the engine reads the
   existing row first to know which one, and attaches the entity's
   current `version` as `SyncOperation.localVersion` (the optimistic-
   concurrency baseline used later to detect conflicts).

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

### `sync()` — draining the queue

`sync()` sends every currently-eligible pending operation through the
configured `SyncTransport`, in the order they were created, and reacts to
the result:

- **Success** → the operation is removed from the queue; the entity is
  marked synced with the server's returned version (or an incremented
  guess if the transport didn't capture one).
- **Retriable failure** (timeout, 5xx) → handled by `RetryPolicy`: the
  operation is marked `failed`, its `retryCount` incremented, and it's
  skipped until `nextRetryAt` passes. Calling `sync()` again before then
  is safe — it just won't resend it yet.
- **Non-retriable failure** (4xx), or once `RetryPolicy.maxAttempts` is
  used up → the operation is marked `exhausted` and no longer retried
  automatically.
- **Conflict** (the server rejected `localVersion` as stale) → handed to
  the configured `ConflictResolver` to pick a winner, then reconciled
  locally. See **Conflict resolution** below.

An operation whose `entityName` has no matching registered adapter is
skipped for that call rather than crashing the whole sync — it's picked
up again once the adapter is registered.

### Checking queue status

Two counters, easy to mix up — pick based on what you're building:

| Method | Counts | Use for |
|---|---|---|
| `OfflineSync.pendingOperationsCount()` | Operations eligible to send **right now** — excludes `failed` rows still waiting out a `RetryPolicy` backoff window. | Driving sync logic itself (rarely needed directly — `sync()` already does this). |
| `OfflineSync.totalQueuedOperationsCount()` | **Every** unsynced operation, including ones mid-backoff. | UI badges/counters — "3 changes not yet synced". This is almost always what you want to show a user. |

A device that just went offline and had a failed send attempt will show
`pendingOperationsCount() == 0` for the next few seconds (nothing is
eligible to retry *yet*) while `totalQueuedOperationsCount() == 1` (the
change is still unsynced). Showing the first number in a UI reads as "all
synced" when it isn't — use `totalQueuedOperationsCount()` for anything
user-facing.

```dart
final pending = await OfflineSync.totalQueuedOperationsCount();
// e.g. show "3 changes pending" in an AppBar chip
```

### Retries and backoff

`RetryPolicy` controls how long `sync()` waits before retrying a
retriable failure — exponential backoff by default (5s, 10s, 20s, ... up
to `maxDelay`), giving up after `maxAttempts` tries:

```dart
await OfflineSync.initialize(
  storage: DriftLocalStorage(),
  transport: DioSyncTransport(dio),
  retryPolicy: const RetryPolicy(
    baseDelay: Duration(seconds: 5),
    maxDelay: Duration(minutes: 30),
    maxAttempts: 8,
  ),
);
```

Tune this per app — e.g. a field data-collection app expecting hours
offline might want a much higher `maxDelay` and `maxAttempts` than a chat
app.

### Conflict resolution

A conflict is detected when the server rejects a write because the
client's `localVersion` no longer matches what the server has. `core`
ships four strategies via `ConflictResolver`, defaulting to
`lastWriteWins` if you don't pass one:

| Strategy | Winner |
|---|---|
| `ConflictResolver.serverWins()` | Server's data |
| `ConflictResolver.clientWins()` | Local data |
| `ConflictResolver.lastWriteWins()` | Whichever side has the more recent `updatedAt` |
| `ConflictResolver.manual((conflict) => ...)` | Whatever your callback returns — e.g. after showing the user a merge dialog |

```dart
conflictResolver: ConflictResolver.manual((conflict) async {
  final merged = Map<String, dynamic>.from(conflict.serverData);
  merged['title'] = conflict.localData['title']; // keep one local edit
  return merged;
}),
```

If the winning content still needs to reach the server (client wins, or a
manual merge), it's automatically re-enqueued with the server's version as
the new baseline so the next `sync()` call succeeds. Pass `onConflict` to
`initialize()` to observe resolutions (logging, analytics, a toast).

## Implementing your own adapters

`offline_sync_drift` and `offline_sync_dio` are the reference
implementations, but any package can provide storage or network transport
by implementing the corresponding contract:

```dart
abstract class LocalStorage {
  Future<void> init();

  Future<int> saveEntity({required String entityName, required String entityId, required Map<String, dynamic> data, required DateTime updatedAt});
  Future<int> softDeleteEntity({required String entityName, required String entityId});
  Future<void> hardDeleteEntity({required String entityName, required String entityId});
  Future<int> markSynced({required String entityName, required String entityId, int? serverVersion});
  Future<void> reconcileEntity({required String entityName, required String entityId, required Map<String, dynamic> data, required int version, required DateTime updatedAt, required bool isSynced});
  Future<Map<String, dynamic>?> getEntity({required String entityName, required String entityId});
  Future<List<Map<String, dynamic>>> getAllEntities(String entityName);

  Future<void> enqueueOperation(SyncOperation operation);
  Future<List<SyncOperation>> getPendingOperations({DateTime? now});
  Future<void> updateOperationStatus(String operationId, SyncOperationStatus status, {int? retryCount, DateTime? nextRetryAt});
  Future<void> removeOperation(String operationId);
  Future<int> totalQueuedOperationsCount();
}
```

```dart
abstract class SyncTransport {
  Future<SyncTransportResult> send(SyncOperation operation, SyncAdapter adapter);
}
```

`SyncTransportResult` has three constructors your transport returns from
`send()`: `.success()`, `.failure()`, and `.conflict()` — see
`offline_sync_dio`'s implementation for how it maps HTTP status codes to
each.

See [`ARCHITECTURE.md`](../../ARCHITECTURE.md) for why the adapter pattern
was chosen over inheritance, and why storage/network packages are split
from `core` in the first place.

## License

MIT (proposed — confirm before first public release).