# offline_sync_workmanager

Background sync scheduling for [`offline_sync_core`](../offline_sync_core),
backed by [`workmanager`](https://pub.dev/packages/workmanager) —
periodically drains the sync queue even while the app is closed
(Android) or suspended (iOS, best-effort).

This package only handles *scheduling*. The actual sync logic has to be
provided by your app — see [Why you write the callback yourself](#why-you-write-the-callback-yourself)
below for why that can't be handled generically.

## Install

```yaml
dependencies:
  offline_sync_core: ^0.0.1
  offline_sync_workmanager: ^0.0.1
```

Also complete `workmanager`'s own platform setup (Android manifest
entries, iOS background modes/capabilities) — see its
[README on pub.dev](https://pub.dev/packages/workmanager) for the exact,
version-specific steps. `offline_sync_workmanager` doesn't duplicate that
here since it changes across `workmanager` releases.

## Setup

```dart
import 'package:dio/dio.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';

/// Runs in a fresh, separate isolate every time — cannot see anything
/// from main(). Must be top-level (or static) and annotated exactly like
/// this, or release builds will silently tree-shake it away and
/// background sync will just never fire, with no error anywhere.
@pragma('vm:entry-point')
void callbackDispatcher() {
  runBackgroundSyncTask(() async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    await OfflineSync.initialize(
      storage: DriftLocalStorage(),   // same on-disk file the app itself uses
      transport: DioSyncTransport(dio),
      autoSync: false,                // no widget tree here to trigger anything from
    );
    OfflineSync.register<User>(userAdapter);
    await OfflineSync.sync();
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await OfflineSync.initialize(/* ... your normal app setup ... */);
  OfflineSync.register<User>(userAdapter);

  await BackgroundSync.initialize(callbackDispatcher: callbackDispatcher);

  runApp(const MyApp());
}
```

That's it — from here on, the queue is drained periodically even when
the app is fully closed.

## Why you write the callback yourself

`callbackDispatcher` runs in a **separate isolate that shares no memory
with your running app**. `OfflineSync`'s state from your main isolate —
its storage connection, registered adapters, transport — simply does not
exist there. `offline_sync_workmanager` cannot rebuild that generically,
because only your app knows its own adapters, endpoints, and auth.

So your `callbackDispatcher` has to fully repeat the relevant parts of
your `main()`'s `OfflineSync.initialize()` — pointing at the *same*
on-disk database (the default `DriftLocalStorage()` constructor already
resolves to the same file path, so this is automatic as long as you use
it the same way in both places).

This is the single most important thing to understand about this
package — see
[ARCHITECTURE.md, decision #10](../../ARCHITECTURE.md#10-background-sync-a-full-re-initialization-boundary-not-shared-state)
for the full reasoning.

## API

### `BackgroundSync.initialize({ callbackDispatcher, frequency, constraints })`

Call once from `main()`, before `runApp()`. Registers a periodic
background task.

- `frequency` (default 15 minutes) is a **minimum** interval, not a
  guarantee — Android enforces a hard floor of 15 minutes for periodic
  work regardless of what you pass, and batches actual execution around
  battery/Doze state. iOS is far less predictable still (see
  [Gotchas](#gotchas)).
- `constraints` (default: `NetworkType.connected`) — passed straight
  through to `workmanager`/`WorkManager`.

### `BackgroundSync.cancel()`

Stops the periodic task.

### `BackgroundSync.scheduleOneOffTest({ constraints })`

Schedules a **one-off** task instead of a periodic one — runs as soon as
its constraints are met, without waiting on any interval. This exists
purely for development: getting a fast, deterministic signal instead of
waiting up to 15+ minutes to see whether things work.

**Must be called while the constraint is genuinely unmet** to prove
anything — see [Gotchas](#gotchas).

### `BackgroundSync.recentAttempts()`

Returns the last 20 recorded [`BackgroundSyncAttempt`](#built-in-diagnostics)s,
newest last. Safe to call from your UI at any time (main isolate).

### `runBackgroundSyncTask(Future<void> Function() performSync)`

Call this from inside your `callbackDispatcher`. Wraps
`Workmanager().executeTask`, routes to your `performSync`, and records
the outcome automatically (see below).

## Built-in diagnostics

A background isolate's `print`/`debugPrint` output doesn't reliably show
up in `adb logcat`, and hand-rolling your own "did it actually run"
logging in every app turned out to be easy to get subtly wrong (see
ARCHITECTURE.md's "Lessons learned" for the specifics). So
`runBackgroundSyncTask` records every attempt for you automatically —
you don't add any logging code yourself:

```dart
final attempts = await BackgroundSync.recentAttempts();
for (final a in attempts) {
  print(a); // e.g. "2026-07-18 13:32:51.202728 — success"
}
```

Each `BackgroundSyncAttempt` has:

| Field | Meaning |
|---|---|
| `startedAt` | When this attempt began. |
| `outcome` | `'success'`, `'failure'`, or `'timeout'`. |
| `detail` | The error message (`failure`), or how long it ran before timing out (`timeout`); `null` on success. |

### Timeout protection

`runBackgroundSyncTask` wraps your `performSync` in a 2-minute timeout
(`kBackgroundSyncTimeout`) by default. If your sync call hangs — a
request with no timeout of its own, stuck against a dead connection —
this reports as `'timeout'` in the log and tells WorkManager to retry,
instead of the job (and your debugging session) waiting indefinitely
with no signal at all.

### ⚠️ "Success" here means "didn't throw" — not "everything sent"

`OfflineSync.sync()` deliberately swallows per-operation errors so one
bad operation can't take down the rest of the queue (see
`SyncRunner`/decision #7 in ARCHITECTURE.md). That means a background
run can log `'success'` here — because `sync()` itself completed without
throwing — while every individual send inside it actually failed. A
`'success'` entry tells you the background task *ran*; it does not by
itself tell you the queue is empty. Check `OfflineSync.pendingOperationsCount()`
(or `totalQueuedOperationsCount()`, if your app tracks all statuses) if
you need to confirm the queue actually drained.

## Testing

`handleBackgroundTask` — the routing/timeout/logging logic behind
`runBackgroundSyncTask` — is a pure function, unit-testable without the
real `workmanager` plugin or a platform channel:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';

void main() {
  test('runs performSync and reports success for our task', () async {
    var called = false;

    final result = await handleBackgroundTask(
      kOfflineSyncTaskName,
      () async => called = true,
    );

    expect(result, isTrue);
    expect(called, isTrue);
  });

  test('reports failure if performSync throws', () async {
    final result = await handleBackgroundTask(
      kOfflineSyncTaskName,
      () async => throw Exception('network unreachable'),
    );

    expect(result, isFalse);
  });
}
```

`BackgroundSync.initialize()`/`cancel()`/`scheduleOneOffTest()` talk to
the real `workmanager` plugin through a platform channel and **cannot**
be exercised in a plain `flutter_test` unit test (no platform binding
available) — validate those manually, on-device. See
[Gotchas](#gotchas).

## Gotchas

These cost real debugging time to work out — saving you that time is the
main point of this section.

- **`flutter run` kills background work.** Whether in debug or
  `--release`, as long as the tooling is still attached to the device (a
  `flutter run` session), stopping it cancels any in-flight `WorkManager`
  task immediately. A task that "gets cancelled the instant I stop the
  app" is not a bug — it's the debugger tearing down the isolate. To
  validate for real: `flutter build apk` (or `--release`) →
  `adb install` → launch from the device's app drawer, with **no**
  `flutter run`/debugger attached at all.
- **`frequency` is a floor, not a promise.** Don't expect exactly-every-N-minutes
  timing, especially on iOS. Use `scheduleOneOffTest()` during
  development instead of waiting on the periodic schedule.
- **Schedule the one-off test while offline, not from `main()`.**
  Registering it at app launch fires almost immediately if the device is
  already online, which proves nothing about "syncs after reconnecting."
  Trigger it from a UI action, deliberately, while airplane mode is on.
- **`@pragma('vm:entry-point')` is not optional.** Omit it and everything
  works in debug builds, then silently does nothing in release — the
  Dart compiler tree-shakes the function away since nothing in the
  visible call graph references it.
- **iOS is fundamentally less reliable than Android here.** `BGTaskScheduler`
  underneath doesn't guarantee timing, or even that the task runs at
  all — the OS decides based on battery and recent app usage. Don't
  design a feature that depends on background sync happening on any
  particular schedule on iOS.

## License

MIT (proposed — confirm before first public release).