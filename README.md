# Flutter Offline Sync Kit

> Offline-First for Flutter, as easy as adding Dio or Riverpod.

**Status:** 🚧 Active development — local persistence and the sync queue are
working end-to-end on Drift/SQLite ([`offline_sync_drift`](packages/offline_sync_drift)).
Network sync (actually sending queued operations to a server) is next.
Not yet published to pub.dev.

## Target usage

```dart
await OfflineSync.initialize();

OfflineSync.register<User>(userAdapter);

await OfflineSync.save(user);
await OfflineSync.sync();
```

Today, `save()` writes to local storage and enqueues the operation
immediately — it never blocks on the network. `sync()` currently drains
that queue locally; it does not yet call a server (see
[Roadmap](#roadmap)).

## Packages

| Package | Status | Purpose |
|---|---|---|
| [`offline_sync_core`](packages/offline_sync_core) | ✅ Stable API | Storage-agnostic contracts + engine |
| [`offline_sync_drift`](packages/offline_sync_drift) | ✅ Phase 1 done | Drift/SQLite storage adapter |
| [`offline_sync_dio`](packages/offline_sync_dio) | ✅ Phase 2 done | Network. Make sync() actually |
| `offline_sync_example` | ⏳ Planned | Demo app |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the foundational decisions and
why they were made.

## Roadmap

- [x] **Phase 0 — Contracts.** `SyncAdapter`, `LocalStorage`, `SyncOperation`,
      and the public `OfflineSync` API.
- [x] **Phase 1 — Local persistence.** Drift/SQLite storage: entities table,
      operation queue, soft delete.
- [x] **Phase 2 — Network.** Make `sync()` actually send queued operations
      to a server (`offline_sync_dio`).
- [ ] **Phase 3 — Retry & backoff.** Exponential backoff on failed sends,
      using the `retryCount` field already in `SyncOperation`.
- [ ] **Phase 4 — Conflict resolution.** Server Wins / Client Wins /
      Last-Write-Wins / Manual, based on the `version` field already in
      `EntitiesTable`.
- [ ] **Phase 5 — Connectivity detection.** Auto-trigger `sync()` when the
      device comes back online.
- [ ] **Phase 6 — Background sync.** Keep syncing while the app is closed.
- [ ] **Phase 7 — Delta sync.** Send/fetch only changed records.
- [ ] **Phase 8 — Compression.** GZIP large payloads.
- [ ] **Phase 9 — Encryption.** At-rest encryption for sensitive local data.
- [ ] **Phase 10 — Logging & observability.**
- [ ] **Phase 11 — Alternative storage adapters.** `offline_sync_isar`,
      `offline_sync_hive`.
- [ ] **Phase 12 — Alternative network adapters.** `offline_sync_graphql`,
      `offline_sync_firebase`, `offline_sync_supabase`.
- [ ] **Phase 13 — Developer tooling.** `offline_sync_cli` (codegen for
      `SyncAdapter`), `offline_sync_devtools` (queue inspector).
- [ ] **Phase 14 — UI kit.** `offline_sync_ui` (offline banner, sync status
      indicator).
- [ ] **Phase 15 — Example app & pub.dev release.**

## Development

```bash
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
```

## Contributing

Issues and PRs are welcome — especially on Phase 2 (network adapter) and
Phase 11/12 (alternative storage/network adapters), since those are
designed as independent packages behind the same `LocalStorage`/
`SyncAdapter` contracts. See [ARCHITECTURE.md](ARCHITECTURE.md) first;
it explains *why* things are structured this way before you change them.

## License

MIT (proposed — confirm before first public release).