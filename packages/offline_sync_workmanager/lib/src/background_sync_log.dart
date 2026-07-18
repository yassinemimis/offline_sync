import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One recorded attempt at running the background sync task.
class BackgroundSyncAttempt {
  const BackgroundSyncAttempt({
    required this.startedAt,
    required this.outcome,
    this.detail,
  });

  final DateTime startedAt;

  /// One of: 'success', 'failure', 'timeout'.
  final String outcome;

  /// Error message (failure) or e.g. "pending 3 -> 0" (success), if the
  /// app's `performSync` chose to report one via [BackgroundSyncLog.record].
  final String? detail;

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'outcome': outcome,
        'detail': detail,
      };

  factory BackgroundSyncAttempt.fromJson(Map<String, dynamic> json) =>
      BackgroundSyncAttempt(
        startedAt: DateTime.parse(json['startedAt'] as String),
        outcome: json['outcome'] as String,
        detail: json['detail'] as String?,
      );

  @override
  String toString() =>
      '$startedAt — $outcome${detail != null ? ' ($detail)' : ''}';
}

/// Built-in diagnostics for background sync runs, persisted via
/// `shared_preferences` so they survive the background isolate exiting
/// (each run is a fresh isolate — nothing in memory survives between
/// runs, this is the only thing that does).
///
/// This exists because "did my background task even run, and what
/// happened" is otherwise invisible — `adb logcat` output from a
/// background isolate is unreliable, and building this by hand in every
/// app (as we found out) is easy to get subtly wrong.
class BackgroundSyncLog {
  BackgroundSyncLog._();

  static const _key = 'offline_sync_workmanager.attempts';
  static const _maxEntries = 20;

  /// Called automatically by [runBackgroundSyncTask] — you normally don't
  /// call this yourself.
  static Future<void> record(BackgroundSyncAttempt attempt) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    raw.add(jsonEncode(attempt.toJson()));
    final trimmed =
        raw.length > _maxEntries ? raw.sublist(raw.length - _maxEntries) : raw;
    await prefs.setStringList(_key, trimmed);
  }

  /// Call this from your UI (main isolate) to show what's actually been
  /// happening in the background — e.g. a debug screen or a hidden
  /// gesture in settings.
  static Future<List<BackgroundSyncAttempt>> recentAttempts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw
        .map((s) => BackgroundSyncAttempt.fromJson(
            jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}