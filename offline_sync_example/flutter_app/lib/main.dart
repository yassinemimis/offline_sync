import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:offline_sync_dio/offline_sync_dio.dart';
import 'package:offline_sync_drift/offline_sync_drift.dart';

import 'pages/home_page.dart';
import 'sync/todo_adapter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dio = Dio(
    BaseOptions(
      // Android Emulator
      baseUrl: "http://10.0.2.2:3000",

   
      // baseUrl: "http://192.168.1.10:3000",
    ),
  );

  await OfflineSync.initialize(
    storage: DriftLocalStorage(),
    transport: DioSyncTransport(dio),
    retryPolicy: const RetryPolicy(
    baseDelay: Duration(seconds: 2), 
    maxAttempts: 3,
  ),
  );

  OfflineSync.register(todoAdapter);

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