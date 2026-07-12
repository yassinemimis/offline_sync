# Architecture Decisions — Phase 0

This document freezes the foundational decisions before any real
implementation starts. Each one is expensive to reverse once other modules
depend on it, so they are made explicit and justified here rather than
implied by code.

## 1. Default storage engine: Drift (not Isar / Hive)

**Decision:** `offline_sync_drift` is the reference/default adapter that
`offline_sync_core` is developed and tested against first. Isar and Hive
become alternative adapters later (Phase 5), behind the same storage
contract.

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
  isolates — required later for the `background` module (WorkManager
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
annotation. We intentionally defer `@SyncModel()` code-generation sugar
to a later phase (`offline_sync_cli`) — ship the manual API first,
generate it later once the shape is proven and stable.

## 3. Monorepo from day one (melos)

**Decision:** a single GitHub repo, managed with
[melos](https://melos.invertase.dev), containing independent packages
under `packages/`:

```
offline_sync/
├── melos.yaml
└── packages/
    ├── offline_sync_core/
    ├── offline_sync_drift/
    └── offline_sync_example/
```

**Why:**
- The long-term plan (per the product vision) is many independent
  packages (`_hive`, `_isar`, `_dio`, `_graphql`, `_firebase`,
  `_supabase`, `_devtools`, `_cli`, `_ui`). Splitting a single package
  into a monorepo later is far more expensive than starting with one.
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

**Why:** already covered in the product doc — the server must receive
an explicit `DELETE`, not silently stop seeing a row.

---

**Status:** these five decisions are considered locked for Phase 1.
Anything not listed here (retry strategy details, conflict resolution
algorithm, compression, encryption) is deliberately left open — it
belongs to later phases and shouldn't block starting `database` +
`queue` now.
