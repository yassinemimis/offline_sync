# Architecture Decisions

This document records the foundational decisions behind the project, in
the order they were made. Each one is expensive to reverse once other
modules depend on it, so they're made explicit and justified here rather
than left implied by code.

## 1. Default storage engine: Drift (not Isar / Hive)

**Decision:** `offline_sync_drift` is the reference/default adapter that
`offline_sync_core` is developed and tested against first. Isar and Hive
can become alternative adapters later, behind the same storage contract.

**Why:**
- The Queue is a relational problem at heart: ordered reads
  (`WHERE status = pending ORDER BY createdAt`), atomic transactions
  (write entity + enqueue operation together), and joins between the
  entity table and the queue table. SQL expresses this naturally; a
  NoSQL object store makes it a hand-rolled index.
- Drift supports transactions, migrations, and `Stream` queries
  (reactive UI) out of the box — all needed for a sync engine that must
  never lose a write.
- Drift works over `sqlite3` via FFI, which also runs in background
  isolates — required by the `background` module (Phase 6, WorkManager
  sync without the app open).
- Isar's long-term maintenance trajectory has been uncertain; building
  the *reference* implementation on it is a risk we don't need to take
  for infra-grade code that other people's production apps will depend
  on. It remains a perfectly fine optional adapter.

**Consequence:** the storage *contract* itself (defined in `core`) must
stay engine-agnostic — no Drift types leak into `offline_sync_core`.

## 2. Contract shape: adapter/registration, not inheritance

**Decision:** developers describe their model via a `SyncAdapter<T>`
(functions: `toJson`, `fromJson`, `getId`, `getUpdatedAt`, `endpoint`)
passed to `OfflineSync.register<T>()`. Models are **not** required to
implement a `Syncable` interface or extend a base class.

**Why:**
- Works unmodified with `freezed`, `json_serializable`, `equatable`, or
  plain Dart classes — no forced inheritance on code the developer may
  not fully own.
- Dart/Flutter AOT builds have no runtime reflection, so an explicit
  adapter is the idiomatic way to teach a generic engine about a
  concrete type (same pattern `Dio`/`Retrofit`/`json_serializable`
  already use).
- Keeps the public API small and mockable in tests: a `SyncAdapter` is
  just a plain object, easy to construct with fakes.

**Trade-off accepted:** slightly more boilerplate than a single
annotation. `@SyncModel()` code-generation sugar (`offline_sync_cli`) is
deliberately deferred — ship the manual API first, generate it later
once the shape is proven and stable.

## 3. Monorepo from day one (melos)

**Decision:** a single GitHub repo, managed with
[melos](https://melos.invertase.dev), containing independent packages
under `packages/`:

```
offline_sync/
├── melos.yaml
└── packages/
    ├── offline_sync_core/          # storage-agnostic contracts + engine
    ├── offline_sync_drift/         # SQLite/Drift storage adapter
    ├── offline_sync_dio/           # Dio-based network transport
    └── offline_sync_workmanager/   # background sync scheduling
offline_sync_example/
└── flutter_app/                    # demo app, deliberately outside packages/
```

**Why:**
- The long-term plan (per the product vision) is many independent
  packages (`_hive`, `_isar`, `_graphql`, `_firebase`, `_supabase`,
  `_devtools`, `_cli`, `_ui`). Splitting a single package into a
  monorepo later is far more expensive than starting with one.
- `melos bootstrap` gives correct local `path:` dependency wiring
  between `core` and adapters during development, without needing
  published versions.
- Each package can be versioned and published to pub.dev
  independently, so `offline_sync_core` staying stable doesn't block
  shipping fixes to `offline_sync_drift`.

## 4. Ids are client-generated strings (UUID)

**Decision:** entity ids are `String` UUIDs generated on the client at
creation time, not server-assigned integers.

**Why:** a `create` operation must be fully valid *before* the device
ever talks to a server (that's the entire point of offline-first). If
ids were server-assigned, a locally created record would have no id
to reference in subsequent local operations (e.g. an `update` queued
seconds later, still offline) or to use as a local foreign key.

## 5. Soft delete only, at the core level

**Decision:** `core` never issues a hard local delete as the *first*
step of `OfflineSync.delete()`. It marks `deleted = true` and enqueues
a `delete` operation; hard deletion (row removal) only happens after
the server acknowledges the delete.

**Why:** the server must receive an explicit `DELETE`, not silently
stop seeing a row.

## 6. Network transport: adapter pattern, same as storage

**Decision:** `sync()` depends only on a `SyncTransport` interface
(`Future<SyncTransportResult> send(SyncOperation, SyncAdapter)`), defined
in `core`. `offline_sync_dio` is the reference/default implementation,
mirroring how `offline_sync_drift` relates to `LocalStorage` (decision
#1). `offline_sync_core` has no `dio`/`http` dependency.

**Why:**
- Same reasoning as decision #1, applied to the network side: the plan
  is multiple transports (`_dio`, `_graphql`, `_firebase`, `_supabase`).
  If `core` imported `dio` directly, every one of those would drag in an
  unused HTTP client dependency.
- Testability: a `NoopSyncTransport` (always succeeds) or a hand-rolled
  fake transport is enough to unit-test the full local write → queue →
  drain loop and the failure path, without a real HTTP client or server
  anywhere in the test.
- **Verb mapping is the transport's job, not core's:** `core` only knows
  `SyncOperationType` (`create`/`update`/`delete`); it never decides
  POST/PUT/DELETE, GraphQL mutation names, or Firestore calls — that
  belongs entirely to the concrete transport, since it varies per
  backend style.

## 7. Retry: exponential backoff with a bounded budget, not infinite retries

**Decision:** `SyncTransportResult` distinguishes `retriable` failures
(timeout, 5xx, no connection) from non-retriable ones (4xx). A
`RetryPolicy` (`baseDelay`, `maxDelay`, `maxAttempts`) governs both the
backoff delay (`nextRetryAt`, stored per operation) and a hard ceiling on
attempts. Once exhausted — either the budget runs out or the failure was
non-retriable — the operation is marked `SyncOperationStatus.exhausted`
and is no longer retried automatically.

**Why:**
- Retrying a validation error (4xx) forever wastes battery/data for an
  outcome that will never change without a code fix on one side or the
  other.
- An unbounded retriable failure (e.g. server down for days) must not
  retry *forever* either — `exhausted` gives the app a clear, queryable
  state to surface to the user or a developer, instead of a queue that
  silently grows.
- `RetryPolicy` is injected at `initialize()`, not hardcoded, because
  "how patient to be" is an app-specific judgment call (a field
  data-collection app expecting hours offline needs a very different
  policy than a chat app).

## 8. Conflict resolution: strategy-based, driven by optimistic concurrency

**Decision:** every entity carries a `version` — "the version last
confirmed with the server," bumped only by `LocalStorage.markSynced`,
never by a plain local write. Each queued operation remembers the
version it was built against (`SyncOperation.localVersion`). A transport
reports a version mismatch as `SyncTransportResult.conflict(serverData,
serverVersion)` (HTTP 409 by REST convention). `core` hands the resulting
`SyncConflict` to a pluggable `ConflictResolver` — built-in strategies:
Server Wins, Client Wins, Last-Write-Wins (default), and Manual (an
app-supplied callback, which may `await` user input).

**Why:**
- `version`, not just `updatedAt`, is what makes conflict *detection*
  possible in the first place — comparing timestamps alone can't tell
  the client and server apart from a clock skew or a legitimately
  concurrent edit; an incrementing counter the server owns can.
- Versioning a local write would break the whole scheme: the client
  would be claiming a baseline the server never acknowledged. `version`
  only ever moves forward via server confirmation.
- Delete conflicts are handled as their own case, not folded into the
  same code path as create/update conflicts — resolving "the record you
  tried to delete changed on the server" by treating the (empty) delete
  payload as competing *data* to merge doesn't make sense.

## 9. Connectivity: adapter pattern, and *not* automatically on every save()

**Decision:** `ConnectivityChecker` (default: `ConnectivityPlusChecker`,
wrapping `connectivity_plus`) is injected the same way as storage and
transport. `OfflineSync.initialize(autoSync: true)` (the default)
subscribes once for the app's lifetime and calls `sync()` whenever
connectivity is restored — including once at startup if already online,
since a connectivity *change* event never fires for a state that hasn't
changed since launch.

Separately, `save()` also makes one **opportunistic** attempt to sync
immediately after enqueuing (fire-and-forget, de-duplicated against any
in-flight `sync()` via the same mechanism `SyncRunner` uses for
concurrent calls) — so the UI doesn't have to wait for a connectivity
*event* that may be seconds away, or manually wire a "try now" button,
to get a fast round-trip when the device is already online.

**Why:**
- "Connected" here means the OS reports an active network interface, not
  verified reachability — checking real reachability adds latency and
  false negatives for networks that block probing, for little benefit:
  if the interface turns out to be a dead end, `sync()` simply fails and
  Retry (decision #7) takes over.
- Auto-sync-on-save and connectivity-triggered auto-sync are
  complementary, not redundant: one covers "just came back online after
  a while", the other covers "already online, don't make the user wait".

## 10. Background sync: a full re-initialization boundary, not shared state

**Decision:** `offline_sync_workmanager` wraps `workmanager`. Critically,
the callback it schedules (`callbackDispatcher`, `@pragma('vm:entry-point')`)
runs in a **separate isolate that shares no memory with the running
app** — `OfflineSync`'s static state from the main isolate simply does
not exist there. The app-provided callback must fully rebuild whatever
`OfflineSync.initialize()` needs (same on-disk storage, a transport,
registered adapters) from scratch, every single time it fires.
`offline_sync_workmanager` cannot do this rebuild generically — only the
app knows its own adapters/endpoints/auth.

Every attempt is logged automatically (`BackgroundSyncLog`, backed by
`shared_preferences`, survivable across isolate boundaries) with a
bounded `timeout` around the app's sync call, so a hung request reports
as `timeout` instead of leaving the WorkManager job — and the developer
— waiting indefinitely with no signal.

**Why:**
- This isolate boundary isn't an implementation detail to hide; it's the
  single most consequential fact about this module, and getting it wrong
  produces confusing, silent failures (see "Lessons learned" below) —
  the API and its docs are built to make the constraint visible rather
  than paper over it.
- Built-in logging exists because building this by hand, per app, turned
  out to be easy to get subtly wrong (see below) — every consumer of
  this package needs the same answer to "did it actually run", so it
  belongs in the package, not re-invented per project.

### Lessons learned validating this module (kept for future contributors)

- **Debug-mode tooling kills background work.** `flutter run` (debug or
  even `--release`, as long as it's still attached to the run daemon)
  cancels any in-flight `WorkManager` task the moment the tooling
  disconnects from the device. A background task that appears to "just
  get cancelled" the instant you stop the app is not a bug in this
  package — it's the debugger tearing down the isolate. Real validation
  requires `flutter build apk` + `adb install`, launched from the
  device's app drawer, with no `flutter run`/debugger attached at all.
- **A periodic task's `frequency` is a floor, not a promise.** Android
  enforces a 15-minute minimum and batches execution around device
  state (battery, Doze); "reconnected but nothing happened for 10
  minutes" is expected, not broken. `registerOneOffTask` exists
  specifically to get a fast, deterministic signal during development —
  it is not itself Phase 6's deliverable.
- **A one-off test task must be scheduled while the constraint is
  genuinely unmet.** Registering it from `main()` fires almost
  immediately if the device is online at launch, which proves nothing
  about "syncs after reconnecting." It has to be scheduled — by a
  dedicated UI action, deliberately — while already offline.
- **"WorkManager reports SUCCESS" only means the callback didn't
  throw.** `SyncRunner` intentionally swallows per-operation errors so
  one bad operation can't take down the rest of the queue (see
  `sync_runner.dart`) — which means a background run can "succeed"
  from WorkManager's point of view while every send inside it failed.
  Don't trust the OS-level result alone; trust `BackgroundSyncLog`,
  which records what `OfflineSync.sync()` actually did.

## 11. `DeltaSyncTransport` as a separate interface, not an added method on `SyncTransport`

**Decision:** Pull (Phase 7) is defined as its own optional interface:

```dart
abstract class DeltaSyncTransport {
  Future<DeltaFetchResult> fetchChanges(SyncAdapter adapter, {DateTime? since});
}
```

`DioSyncTransport implements SyncTransport, DeltaSyncTransport` — both,
but as two separate interfaces.

**Why:** Adding a new *required* method directly to `SyncTransport` would
have been a breaking change — any existing code (including the example
documented in `Network_Layer.mdx`) that does `implements SyncTransport`
would fail to compile immediately. A separate interface lets any
existing transport keep working unchanged (with no pull support), and
makes enabling pull entirely opt-in — the engine checks
`transport is DeltaSyncTransport` at call time and throws a clear
`StateError` if it isn't supported, instead of a silent failure or a
compile break.

**Consequence:** any future transport (GraphQL, Firebase — Phase 12) is
free to decide whether it supports delta pull or not, with no forced
obligation either way.

## 12. A dedicated sync-cursor table, not one computed from `MAX(updatedAt)`

**Decision:** `SyncCursorsTable` (Drift) — one row per `entityName`, a
single `lastSyncedAt` column.

**Why:** The alternative (dynamically computing the cursor from the
newest `updatedAt` in `EntitiesTable`) is dangerous: if there's a local
edit that hasn't synced yet, its local `updatedAt` can end up newer than
anything actually confirmed with the server — so the cursor "jumps
forward" incorrectly, and misses genuine server-side changes that are
older than the local edit but newer than the last real pull. A dedicated
table cleanly separates "last successful sync" from "last local edit."

**Trade-off:** a single `DateTime` column instead of a more general
design (a string `cursorToken` that could support pagination tokens from
GraphQL/Firebase later). A deliberate choice — not designing for a
problem we haven't reached yet.

## 13. `ConflictHandler` is reused verbatim between push-detected and pull-detected conflicts

**Decision:** A conflict detected via `409` (push) and a conflict
detected via `DeltaPuller` (pull) both go through the **same**
`ConflictHandler.resolve()`, with no separate branch of logic.
`DeltaPuller` constructs a synthetic
`SyncTransportResult.conflict(serverData, serverVersion)` from a
`DeltaRecord` specifically for this purpose.

**Why:** a conflict is defined the same way regardless of *how* it was
discovered (a rejected send attempt, or a pull that surfaces a server
change colliding with a pending local edit) — writing a second, separate
resolution path would have duplicated logic (violating DRY) and created
an extra opportunity for inconsistent behavior between the two paths.

**Known gap (deliberately unresolved):** if push resolves a conflict
within the same `sync()` call (re-enqueuing from a `clientWins`
outcome), the pull phase that immediately follows may detect the same
item as "changed" and trigger a second conflict resolution on the same
state. Documented as a TODO comment in `OfflineSync.sync()`; not yet
exercised by a real-world test scenario.

**Known gap #2:** "deleted on the server" vs. "pending local edit"
conflicts currently always resolve in the server's favor (regardless of
the chosen strategy), because "recreating a resource the server deleted"
is a different behavioral decision than resolving an ordinary data
conflict, and hasn't been settled yet.

## 14. `SyncAdapter<T>.updatedAtFromJson()` — containing generics unsoundness

**Decision:** instead of reading `adapter.getUpdatedAt(adapter.fromJson(json))`
from code holding a **raw** `SyncAdapter` reference (without `<T>`, as is
the case in `AdapterRegistry.byEntityName()`), a method was added inside
`SyncAdapter<T>` itself:

```dart
DateTime updatedAtFromJson(Map<String, dynamic> json) => getUpdatedAt(fromJson(json));
```

**Why:** `getUpdatedAt` is typed `DateTime Function(T)` — `T` appears in
*input* position. Reading it as a standalone value through a raw
(non-generic) reference is unsound in Dart, and throws a `TypeError` at
runtime even when the actual call was logically valid. Wrapping it in a
method whose external signature never mentions `T` at all fixes this:
`T` stays contained inside the method body and never "leaks" into a
value type read from the outside. This issue was discovered for real
while testing Phase 7 (Pull), via an actual runtime error — not
theoretical analysis.

**Consequence:** any future code that needs `updatedAt` from a raw
`SyncAdapter` (referenced by `entityName`, not by `Type`) should use
`updatedAtFromJson`, not the old manual composition.

---

**Status:** decisions #1–#10 are locked as of Phase 6. Decisions
#11–#14 were added after completing and manually device-testing Phase 7
(Delta Sync). Compression, encryption, and logging/observability beyond
`BackgroundSyncLog` are deliberately left open — they belong to later
phases.