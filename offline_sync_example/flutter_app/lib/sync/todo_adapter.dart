import 'package:offline_sync_core/offline_sync_core.dart';

import '../models/todo.dart';

final todoAdapter = SyncAdapter<Todo>(
  entityName: 'Todo',
  endpoint: '/todos',

  toJson: (todo) => todo.toJson(),

  fromJson: (json) => Todo.fromJson(json),

  getId: (todo) => todo.id,

  getUpdatedAt: (todo) => todo.updatedAt,
);