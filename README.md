# Flutter Offline Sync Kit

> Offline-First for Flutter, as easy as adding Dio or Riverpod.

**Status:** 🚧 Phase 0 — foundation. Public API is frozen (see
[`offline_sync_core`](packages/offline_sync_core)); implementation starts
in Phase 1. Not yet published to pub.dev.

## Target usage

```dart
await OfflineSync.initialize();

OfflineSync.register<User>(userAdapter);

await OfflineSync.save(user);
await OfflineSync.sync();
```

## Packages

| Package | Status | Purpose |
|---|---|---|
| [`offline_sync_core`](packages/offline_sync_core) | 🚧 API frozen | Storage-agnostic contracts + engine |
| [`offline_sync_drift`](packages/offline_sync_drift) | ⏳ Phase 1 | Drift/SQLite storage adapter |
| `offline_sync_example` | ⏳ Phase 3 | Demo app |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the foundational decisions and
why they were made.

## Development

```bash
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
```

## License

MIT (proposed — confirm before first public release).
