import 'package:flutter_test/flutter_test.dart';
import 'package:offline_sync_core/offline_sync_core.dart';

void main() {
  group('RetryPolicy.delayFor', () {
    const policy = RetryPolicy(
      baseDelay: Duration(seconds: 5),
      maxDelay: Duration(minutes: 30),
      maxAttempts: 8,
    );

    test('doubles the delay on each successive attempt', () {
      expect(policy.delayFor(1), const Duration(seconds: 5));
      expect(policy.delayFor(2), const Duration(seconds: 10));
      expect(policy.delayFor(3), const Duration(seconds: 20));
      expect(policy.delayFor(4), const Duration(seconds: 40));
    });

    test('never exceeds maxDelay', () {
      expect(policy.delayFor(20), const Duration(minutes: 30));
    });
  });

  group('RetryPolicy.hasAttemptsLeft', () {
    const policy = RetryPolicy(maxAttempts: 3);

    test('true while under the budget, false once it is used up', () {
      expect(policy.hasAttemptsLeft(1), isTrue);
      expect(policy.hasAttemptsLeft(2), isTrue);
      expect(policy.hasAttemptsLeft(3), isFalse);
      expect(policy.hasAttemptsLeft(4), isFalse);
    });
  });

  group('RetryPolicy.nextRetryAt', () {
    const policy = RetryPolicy(baseDelay: Duration(seconds: 5));

    test('adds delayFor(retryCount) to the given now', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final next = policy.nextRetryAt(1, now: now);
      expect(next, now.add(const Duration(seconds: 5)));
    });
  });
}
