import 'package:dio/dio.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

/// [SyncTransport] backed by [Dio].
///
/// Verb mapping, by [SyncOperationType]:
///
/// | Type     | Verb   | URL                          | Body               |
/// |----------|--------|-------------------------------|--------------------|
/// | create   | POST   | `adapter.endpoint`             | `operation.payload` |
/// | update   | PUT    | `adapter.endpoint/entityId`    | `operation.payload` |
/// | delete   | DELETE | `adapter.endpoint/entityId`    | `_version` (query)  |
///
/// Every `update`/`delete` sends `_version` (from
/// [SyncOperation.localVersion]) as an optimistic-concurrency token. The
/// server is expected to respond `409` — with its current copy of the
/// entity as the body, `_version` included — if that token is stale;
/// that's mapped to [SyncTransportResult.conflict] below. This is a
/// convention this package assumes; adjust to match your actual backend
/// if it differs (that's exactly why [SyncTransport] is an interface and
/// not hardcoded into `core` — see ARCHITECTURE.md, decision #6).
///
/// Pass in your own [Dio] instance so this package never has an opinion
/// on `baseUrl`, auth headers, interceptors, or timeouts — configure
/// those on the [Dio] you construct, the same as you would for any other
/// use of Dio in the app.
///
/// ```dart
/// final dio = Dio(BaseOptions(
///   baseUrl: 'https://api.example.com',
///   headers: {'Authorization': 'Bearer $token'},
/// ));
///
/// await OfflineSync.initialize(
///   storage: DriftLocalStorage(),
///   transport: DioSyncTransport(dio),
/// );
/// ```
class DioSyncTransport implements SyncTransport {
  DioSyncTransport(this._dio);
  final Dio _dio;

  @override
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  ) async {
    try {
      switch (operation.type) {
        case SyncOperationType.create:
          // No version to check yet — this is a brand new row.
          await _dio.post(adapter.endpoint, data: operation.payload);
          return const SyncTransportResult.success();

        case SyncOperationType.update:
          final response = await _dio.put(
            '${adapter.endpoint}/${operation.entityId}',
            data: {...operation.payload, '_version': operation.localVersion},
          );
          return SyncTransportResult.success(
            serverVersion: (response.data is Map)
                ? (response.data['_version'] as num?)?.toInt()
                : null,
          );

        case SyncOperationType.delete:
          // Body on DELETE is dropped by some proxies/servers — the
          // version token goes in the query string instead, so it
          // reliably reaches the server either way.
          await _dio.delete(
            '${adapter.endpoint}/${operation.entityId}',
            queryParameters: {'_version': operation.localVersion},
          );
          return const SyncTransportResult.success();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;

      if (status == 409) {
        final raw = e.response?.data;
        if (raw is! Map || !raw.containsKey('_version')) {
          // Unexpected 409 shape (e.g. a proxy/gateway error, not our
          // API) — treat as a plain failure rather than inventing a
          // conflict with no real server data behind it.
          return SyncTransportResult.failure(
            retriable: false,
            message: 'Received 409 with an unexpected body shape',
          );
        }

        final body = Map<String, dynamic>.from(raw);
        final serverVersion = (body.remove('_version') as num?)?.toInt() ?? 0;
        return SyncTransportResult.conflict(
          serverData: body,
          serverVersion: serverVersion,
        );
      }

      final retriable = status == null || status >= 500;
      return SyncTransportResult.failure(
        retriable: retriable,
        message: e.message ?? e.type.name,
      );
    }
  }
}