import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';
import 'package:workmanager/workmanager.dart';
import 'pages/home_page.dart';
import 'sync/todo_adapter.dart';

const _apiBaseUrl = "http://10.0.2.2:3000";

/// Runs in a fresh, separate isolate — cannot see anything from main().
/// Must be top-level (or static) and annotated exactly like this, or
/// release builds will silently tree-shake it away and background sync
/// will just never fire, with no error anywhere.
@pragma('vm:entry-point')
void callbackDispatcher() {
  runBackgroundSyncTask(() async {
    final dio = Dio(BaseOptions(baseUrl: _apiBaseUrl));
    await OfflineSync.initialize(
      storage: DriftLocalStorage(), // same sqlite file the app itself uses
      transport: DioSyncTransport(dio),
      retryPolicy:
          const RetryPolicy(baseDelay: Duration(seconds: 2), maxAttempts: 3),
      autoSync: false, // no UI/widget tree here to trigger anything from
    );
    OfflineSync.register(todoAdapter);
    await OfflineSync.sync();
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dio = Dio(BaseOptions(baseUrl: _apiBaseUrl));

  await OfflineSync.initialize(
    storage: DriftLocalStorage(),
    transport: DioSyncTransport(dio),
    retryPolicy:
        const RetryPolicy(baseDelay: Duration(seconds: 2), maxAttempts: 3),
    onConflict: (conflict, winningData) {
      debugPrint(
        '⚠ Conflict resolved for ${conflict.entityName}/${conflict.entityId}: '
        'local(v${conflict.localVersion}) vs server(v${conflict.serverVersion}) '
        '→ winner: ${identical(winningData, conflict.serverData) ? "server" : "client"}',
      );
    },
    autoSync: true, // Phase 5: syncs automatically while the app is open
  );
  OfflineSync.register(todoAdapter);

  // Phase 6: also sync periodically while the app is closed.
  await BackgroundSync.initialize(callbackDispatcher: callbackDispatcher);

  await Workmanager().registerOneOffTask(
    'test-one-off',
    kOfflineSyncTaskName,
    constraints: Constraints(networkType: NetworkType.connected),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Offline Sync Example",
      home: const HomePage(),
    );
  }
}