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
        case SyncOperationType.update:
          await _dio.put(
            '${adapter.endpoint}/${operation.entityId}',
            data: {...operation.payload, '_version': operation.localVersion},
          );
        case SyncOperationType.delete:
          await _dio.delete(
            '${adapter.endpoint}/${operation.entityId}',
            data: {'_version': operation.localVersion},
          );
      }
      return const SyncTransportResult.success();
    } on DioException catch (e) {
      final status = e.response?.statusCode;

      if (status == 409) {
        // Server's convention: 409 body = its current copy of the
        // entity, with `_version` mixed in — strip it back out before
        // handing the data to the adapter/conflict resolver.
        final raw = e.response?.data;
        final body = raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
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