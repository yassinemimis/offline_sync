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
/// | delete   | DELETE | `adapter.endpoint/entityId`    | — |
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
  const DioSyncTransport(this._dio);

  final Dio _dio;

  @override
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  ) async {
    try {
      switch (operation.type) {
        case SyncOperationType.create:
          await _dio.post(adapter.endpoint, data: operation.payload);
        case SyncOperationType.update:
          await _dio.put(
            '${adapter.endpoint}/${operation.entityId}',
            data: operation.payload,
          );
        case SyncOperationType.delete:
          await _dio.delete('${adapter.endpoint}/${operation.entityId}');
      }
      return const SyncTransportResult.success();
    } on DioException catch (e) {
      return SyncTransportResult.failure(
        retriable: _isRetriable(e),
        message: e.message ?? e.type.name,
      );
    }
  }

  /// Timeouts, connection errors, and 5xx responses are worth retrying
  /// (Phase 3) — the request itself was probably fine, the server or
  /// network just didn't cooperate this time. A 4xx means the server
  /// actively rejected the request (bad payload, validation, auth) —
  /// retrying the exact same request won't help without a code change.
  bool _isRetriable(DioException e) {
    final status = e.response?.statusCode;
    if (status != null && status >= 400 && status < 500) return false;
    return true;
  }
}
