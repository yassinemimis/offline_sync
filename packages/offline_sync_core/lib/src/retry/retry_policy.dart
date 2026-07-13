/// Exponential backoff policy consumed by `OfflineSync.sync()` on a
/// retriable send failure ([SyncTransportResult.retriable] == `true`).
///
/// The delay before attempt N (1-indexed) is:
///
/// ```
/// min(maxDelay, baseDelay * 2^(N-1))
/// ```
///
/// With the defaults (`baseDelay: 5s`, `maxDelay: 30m`), that's
/// approximately: 5s, 10s, 20s, 40s, 80s, 160s, 320s, 640s — capped at 30
/// minutes from there on. After [maxAttempts] failures, the operation
/// stops being retried automatically and is marked
/// [SyncOperationStatus.exhausted] instead of
/// [SyncOperationStatus.failed] — see `OfflineSync.sync()`.
///
/// A non-retriable failure (e.g. a 4xx from [SyncTransportResult.
/// failure]) skips backoff entirely and goes straight to `exhausted`,
/// since retrying the identical request is not expected to ever change
/// the outcome.
///
/// Pass a custom instance to `OfflineSync.initialize()` to tune this per
/// app — e.g. a field data-collection app expecting hours offline might
/// want a much higher `maxDelay` and `maxAttempts` than a chat app.
class RetryPolicy {
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 5),
    this.maxDelay = const Duration(minutes: 30),
    this.maxAttempts = 8,
})  : assert(maxAttempts > 0, 'maxAttempts must be at least 1');

  /// Delay before the 1st retry attempt.
  final Duration baseDelay;

  /// Ceiling on the backoff delay, however many attempts have failed.
  final Duration maxDelay;

  /// How many total attempts (including the first) an operation gets
  /// before it's marked [SyncOperationStatus.exhausted] and stops being
  /// retried automatically.
  final int maxAttempts;

  /// Whether an operation that has failed [retryCount] times so far still
  /// has attempts left under this policy.
  bool hasAttemptsLeft(int retryCount) => retryCount < maxAttempts;

  /// How long to wait before attempt number [retryCount] (1-indexed: the
  /// value *after* incrementing on the failure that just happened).
  Duration delayFor(int retryCount) {
    final exponent = (retryCount - 1).clamp(0, 30);
    // 2^30 seconds already vastly exceeds any sane maxDelay, so clamping
    // the exponent avoids integer overflow on very high retry counts
    // without changing the effective (capped) result.
    final raw = baseDelay * (1 << exponent);
    return raw > maxDelay ? maxDelay : raw;
  }

  /// Absolute point in time attempt number [retryCount] becomes eligible.
  DateTime nextRetryAt(int retryCount, {DateTime? now}) {
    return (now ?? DateTime.now()).add(delayFor(retryCount));
  }
}
