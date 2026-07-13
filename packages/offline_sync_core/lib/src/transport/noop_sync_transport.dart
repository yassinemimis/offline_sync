import '../contracts/sync_adapter.dart';
import '../contracts/sync_operation.dart';
import '../contracts/sync_transport.dart';

/// A [SyncTransport] that always reports success without sending
/// anything anywhere.
///
/// Use this for:
/// - Unit tests of the local write → queue → drain loop that don't care
///   about network behavior (see `offline_sync_drift`'s
///   `offline_sync_flow_test.dart`).
/// - Early demos/prototypes that want `OfflineSync.sync()` to compile and
///   run before a real backend or `offline_sync_dio` is wired up.
///
/// Do not use this in production — operations are discarded, not sent.
class NoopSyncTransport implements SyncTransport {
  const NoopSyncTransport();

  @override
  Future<SyncTransportResult> send(
    SyncOperation operation,
    SyncAdapter adapter,
  ) async {
    return const SyncTransportResult.success();
  }
}