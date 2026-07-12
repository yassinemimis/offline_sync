import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:offline_sync_core/offline_sync_core.dart'; 
import '../tables/entities_table.dart';
import '../tables/sync_operations_table.dart';

part 'app_database.g.dart';

/// The concrete Drift database backing [DriftLocalStorage].
///
/// NOTE: `app_database.g.dart` is generated. After pulling this file, run:
/// `dart run build_runner build --delete-conflicting-outputs`
/// from `packages/offline_sync_drift/`.
@DriftDatabase(tables: [EntitiesTable, SyncOperationsTable])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// For tests — pass an in-memory executor.
  AppDatabase.withExecutor(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 1;
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'offline_sync.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
