import 'package:flutter/material.dart';
import 'package:offline_sync_core/offline_sync_core.dart';
import 'package:uuid/uuid.dart';

import '../models/todo.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final uuid = const Uuid();

  Future<void> _createTodo() async {
    final todo = Todo(
      id: uuid.v4(),
      title: "Todo ${DateTime.now().millisecondsSinceEpoch}",
      completed: false,
      updatedAt: DateTime.now(),
    );

    await OfflineSync.save(todo);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Todo saved"),
      ),
    );
  }

  Future<void> _sync() async {
    await OfflineSync.sync();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Sync completed"),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Offline Sync Example"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _createTodo,
              child: const Text("Create Todo"),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _sync,
              child: const Text("Sync"),
            ),
          ],
        ),
      ),
    );
  }
}