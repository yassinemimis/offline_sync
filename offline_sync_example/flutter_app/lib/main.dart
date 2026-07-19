import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';
import 'package:offline_sync_workmanager/offline_sync_workmanager.dart';

import 'pages/home_page.dart';
import 'sync/todo_adapter.dart';

const _apiBaseUrl = "http://10.0.2.2:3000";

/// Runs in a fresh, separate isolate — cannot see anything from main().
/// Must be top-level (or static) and annotated exactly like this, or
/// release builds will silently tree-shake it away and background sync
/// will just never fire, with no error anywhere.
///
/// No manual logging needed here anymore — runBackgroundSyncTask records
/// success/failure/timeout automatically (see BackgroundSync.recentAttempts()
/// in home_page.dart).
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

    // ── Conflict testing: swap ONE of these four, full-restart between
    // each test. Only one should be active (uncommented) at a time. ──

    // 1) Server Wins
    // conflictResolver: const ConflictResolver.serverWins(),

    // 2) Client Wins
     conflictResolver: const ConflictResolver.clientWins(),

    // 3) Last Write Wins (default — same as omitting this param entirely)
    // conflictResolver: const ConflictResolver.serverWins(),

    // 4) Manual — uncomment this block INSTEAD of the line above,
    // comment the line above out when testing this one.
    // conflictResolver: ConflictResolver.manual((conflict) {
    //   debugPrint(
    //     ' Manual resolver called for ${conflict.entityName}/${conflict.entityId}\n'
    //     '   local : v${conflict.localVersion}  "${conflict.localData['title']}"  (${conflict.localUpdatedAt})\n'
    //     '   server: v${conflict.serverVersion}  "${conflict.serverData['title']}"  (${conflict.serverUpdatedAt})',
    //   );
    //   return conflict.localData; // swap to conflict.serverData to test the other direction
    // }),

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

  // Phase 6: also sync periodically while the app is closed. Registering
  // a one-off *test* task no longer happens here — main() runs at app
  // launch while the device is typically still online, so the task would
  // fire almost immediately and defeat the point of testing "while
  // offline, then reconnect". Use the "Schedule BG Test" button in the
  // UI instead, timed deliberately while offline.
  await BackgroundSync.initialize(callbackDispatcher: callbackDispatcher);

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