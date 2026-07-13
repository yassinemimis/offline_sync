import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';

/// A minimal fake [HttpClientAdapter] — no real sockets, no extra test
/// dependency. It records the last request it saw and returns whatever
/// [respond] is configured to return.
class _FakeHttpClientAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;
  int statusCode = 200;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (statusCode >= 400) {
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: statusCode),
        type: DioExceptionType.badResponse,
      );
    }
    return ResponseBody.fromString('{}', statusCode);
  }
}

final _adapter = SyncAdapter<Map<String, dynamic>>(
  entityName: 'Widget',
  endpoint: '/api/widgets',
  toJson: (m) => m,
  fromJson: (json) => json,
  getId: (m) => m['id'] as String,
  getUpdatedAt: (m) => DateTime.parse(m['updatedAt'] as String),
);

SyncOperation _op(SyncOperationType type) => SyncOperation(
      id: 'op1',
      entityName: 'Widget',
      entityId: 'w1',
      type: type,
      payload: const {'name': 'Bolt'},
      createdAt: DateTime.now(),
    );

void main() {
  late _FakeHttpClientAdapter fake;
  late DioSyncTransport transport;

  setUp(() {
    fake = _FakeHttpClientAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = fake;
    transport = DioSyncTransport(dio);
  });

  test('create -> POST to the bare endpoint', () async {
    final result = await transport.send(_op(SyncOperationType.create), _adapter);

    expect(result.isSuccess, isTrue);
    expect(fake.lastRequest!.method, 'POST');
    expect(fake.lastRequest!.uri.path, '/api/widgets');
  });

  test('update -> PUT to endpoint/entityId', () async {
    final result = await transport.send(_op(SyncOperationType.update), _adapter);

    expect(result.isSuccess, isTrue);
    expect(fake.lastRequest!.method, 'PUT');
    expect(fake.lastRequest!.uri.path, '/api/widgets/w1');
  });

  test('delete -> DELETE to endpoint/entityId', () async {
    final result = await transport.send(_op(SyncOperationType.delete), _adapter);

    expect(result.isSuccess, isTrue);
    expect(fake.lastRequest!.method, 'DELETE');
    expect(fake.lastRequest!.uri.path, '/api/widgets/w1');
  });

  test('4xx response -> failure, not retriable', () async {
    fake.statusCode = 422;

    final result = await transport.send(_op(SyncOperationType.create), _adapter);

    expect(result.isSuccess, isFalse);
    expect(result.retriable, isFalse);
  });

  test('5xx response -> failure, retriable', () async {
    fake.statusCode = 500;

    final result = await transport.send(_op(SyncOperationType.create), _adapter);

    expect(result.isSuccess, isFalse);
    expect(result.retriable, isTrue);
  });
}
