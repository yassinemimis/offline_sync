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

  List<Todo> _todos = [];
  int _pendingCount = 0;
  bool _syncing = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final todos = await OfflineSync.getAll<Todo>();
    final pending = await OfflineSync.pendingOperationsCount();
    if (!mounted) return;
    setState(() {
      _todos = todos;
      _pendingCount = pending;
      _loading = false;
    });
  }

  Future<void> _createTodo() async {
    final todo = Todo(
      id: uuid.v4(),
      title: "Todo ${DateTime.now().millisecondsSinceEpoch}",
      completed: false,
      updatedAt: DateTime.now(),
    );

    await OfflineSync.save(todo);
    await _refresh();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Todo saved locally")),
    );
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final before = _pendingCount;

    await OfflineSync.sync();
    await _refresh();

    if (!mounted) return;
    setState(() => _syncing = false);

    final resolvedCount = before - _pendingCount;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          resolvedCount > 0
              ? "Sync completed — $resolvedCount operation(s) processed"
              : "Sync completed — nothing to send",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Offline Sync Example"),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Chip(
                label: Text('$_pendingCount pending'),
                backgroundColor: _pendingCount == 0
                    ? Colors.green.shade100
                    : Colors.amber.shade100,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _createTodo,
                  child: const Text("Create Todo"),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _syncing ? null : _sync,
                  child: _syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text("Sync"),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _todos.isEmpty
                    ? const Center(child: Text("No todos yet — create one"))
                    : ListView.builder(
                        itemCount: _todos.length,
                        itemBuilder: (context, index) {
                          final todo = _todos[index];
                          return ListTile(
                            leading: Icon(
                              todo.completed
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(todo.title),
                            subtitle: Text(
                              'id: ${todo.id}\nupdated: ${todo.updatedAt}',
                            ),
                            isThreeLine: true,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}