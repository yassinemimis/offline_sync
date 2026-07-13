# offline_sync_dio

Dio-based network transport for
[`offline_sync_core`](../offline_sync_core). Implements the `SyncTransport`
contract: maps `SyncOperationType` to HTTP verbs and turns Dio responses/
errors into a `SyncTransportResult`.

You don't call anything in this package directly except
`DioSyncTransport(dio)` — everything else is driven through `OfflineSync`
from `offline_sync_core`.

## Install

```yaml
dependencies:
  offline_sync_core: ^0.0.1
  offline_sync_dio: ^0.0.1
```

## Setup

```dart
import 'package:dio/dio.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';

final dio = Dio(BaseOptions(
  baseUrl: 'https://api.example.com',
  headers: {'Authorization': 'Bearer $token'},
));

await OfflineSync.initialize(
  storage: DriftLocalStorage(),
  transport: DioSyncTransport(dio),
);
```

`offline_sync_dio` never configures `baseUrl`, auth headers, interceptors,
or timeouts itself — it has no opinion on any of that. Configure your own
`Dio` instance exactly like you would anywhere else in the app, and pass
it in.

## Verb mapping

`DioSyncTransport` reads `SyncAdapter.endpoint` and the queued
`SyncOperation.type` and picks the verb for you:

| `SyncOperationType` | Verb | URL | Body |
|---|---|---|---|
| `create` | `POST` | `adapter.endpoint` | `operation.payload` |
| `update` | `PUT` | `adapter.endpoint/entityId` | `operation.payload` |
| `delete` | `DELETE` | `adapter.endpoint/entityId` | — |

So for `SyncAdapter<User>(endpoint: '/api/users', ...)`:

- create → `POST /api/users`
- update → `PUT /api/users/<id>`
- delete → `DELETE /api/users/<id>`

If your backend uses `PATCH` for partial updates, or a different URL
shape entirely, that's a reason to write your own `SyncTransport` — see
[Writing your own transport](#writing-your-own-transport) below.

## Error mapping

`core` doesn't retry anything yet (that's Phase 3), but `sync()` does
need to know whether to keep an operation queued as `failed`. Every
`DioException` becomes a `SyncTransportResult.failure`, with `retriable`
set based on the response status:

| Status | `retriable` | Reasoning |
|---|---|---|
| `4xx` (400, 404, 422, ...) | `false` | The server actively rejected the request — validation, auth, bad payload. Sending the exact same bytes again won't change the outcome without a code fix. |
| `5xx`, timeout, no connection | `true` | Likely transient — the server or network just didn't cooperate this time. |

Either way, today the operation is simply marked
`SyncOperationStatus.failed` and its `retryCount` is incremented — see
`offline_sync_core`'s `OfflineSync.sync()`. The `retriable` flag is
carried through now so Phase 3 (backoff, retry limits, giving up on
non-retriable failures) can use it without another breaking change.

## Writing your own transport

If your backend doesn't fit REST/`dio` (GraphQL, Firebase, a different
verb/URL convention), implement `SyncTransport` directly instead of using
this package — it's a single method:

```dart
class MyTransport implements SyncTransport {
  @override
  Future<SyncTransportResult> send(SyncOperation operation, SyncAdapter adapter) async {
    // your logic — return SyncTransportResult.success() or .failure(...)
  }
}
```

`offline_sync_dio` is the reference implementation, not a required
dependency — `core` only ever depends on the `SyncTransport` interface.

## Testing

`DioSyncTransport` only depends on `Dio`, so tests swap out
`dio.httpClientAdapter` for a fake instead of hitting a real network —
see `test/dio_sync_transport_test.dart` for the full pattern (covers all
three verbs, plus 4xx/5xx → `retriable` mapping).

## License

MIT (proposed — confirm before first public release).