import 'dart:async';

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

  // Same checker OfflineSync uses internally for auto-sync (Phase 5) —
  // reused here purely to *display* status; connectivity_plus's stream is
  // broadcast, so this listener doesn't interfere with OfflineSync's own.
  final _connectivity = const ConnectivityPlusChecker();
  StreamSubscription<bool>? _connectivitySubscription;
  bool _online = true;

  List<Todo> _todos = [];
  int _pendingCount = 0;
  bool _syncing = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _watchConnectivity();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _watchConnectivity() async {
    _online = await _connectivity.hasConnection();
    if (mounted) setState(() {});

    _connectivitySubscription =
        _connectivity.onConnectivityChanged.listen((isOnline) async {
      if (!mounted) return;
      setState(() => _online = isOnline);

      if (isOnline) {
        // OfflineSync.sync() was just triggered automatically (Phase 5) —
        // give it a moment to actually run, then refresh the UI so the
        // pending count visibly drops without anyone touching "Sync".
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🔄 Back online — syncing automatically..."),
            duration: Duration(seconds: 2),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await _refresh();
      }
    });
  }

  Future<void> _refresh() async {
    final todos = await OfflineSync.getAll<Todo>();
    final pending = await OfflineSync.totalQueuedOperationsCount();
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

  // save() triggers an opportunistic sync in the background
  // (fire-and-forget) — it hasn't necessarily finished by the time we
  // get here. Refresh again shortly after so "pending" reflects the
  // outcome without needing a manual "Sync now" press.
  Future<void>.delayed(const Duration(seconds: 1), () {
    if (mounted) _refresh();
  });
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
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(
              child: Chip(
                avatar: Icon(
                  _online ? Icons.wifi : Icons.wifi_off,
                  size: 18,
                  color: _online ? Colors.green.shade800 : Colors.red.shade800,
                ),
                label: Text(_online ? 'Online' : 'Offline'),
                backgroundColor:
                    _online ? Colors.green.shade100 : Colors.red.shade100,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
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
          if (!_online)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: const Text(
                "You're offline — todos are still saved locally and will "
                "sync automatically once you're back online (Phase 5).",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
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
                      : const Text("Sync now"),
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