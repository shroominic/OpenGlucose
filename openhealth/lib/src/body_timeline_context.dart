import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';

/// Foreground-only states for the local body-context snapshot.
enum BodyTimelineContextStatus { idle, loading, ready, empty, error }

/// Creates a local journal service for one bounded context read.
///
/// The factory is intentionally injected so tests can use an in-memory
/// repository. Production callers should open the protected on-device store;
/// this controller never creates a network client or schedules background
/// work.
typedef BodyTimelineContextServiceFactory = Future<JournalService> Function();

/// Loads today's local context for the Today body timeline.
///
/// A controller owns one short-lived repository connection per foreground
/// load. It does not retain raw records in native surfaces, and it converts
/// storage errors into a stable user-facing message rather than exposing
/// database paths or exception details.
class BodyTimelineContextController extends ChangeNotifier {
  BodyTimelineContextController({
    required BodyTimelineContextServiceFactory serviceFactory,
    DateTime Function()? now,
  }) : _serviceFactory = serviceFactory,
       _now = now ?? DateTime.now;

  final BodyTimelineContextServiceFactory _serviceFactory;
  final DateTime Function() _now;

  BodyTimelineContextStatus _status = BodyTimelineContextStatus.idle;
  JournalContext? _context;
  String? _error;
  Future<void>? _loadFuture;
  bool _loaded = false;
  bool _disposed = false;

  BodyTimelineContextStatus get status => _status;
  JournalContext? get context => _context;
  String? get error => _error;
  bool get isLoading => _status == BodyTimelineContextStatus.loading;

  /// Loads today's local context once until [force] is requested.
  ///
  /// Concurrent callers share one in-flight operation, which keeps a resume
  /// callback and a pull-to-refresh callback from opening duplicate databases.
  Future<void> load({bool force = false}) {
    final existing = _loadFuture;
    if (existing != null) return existing;
    if (_loaded && !force) return Future<void>.value();

    final operation = _loadInternal();
    _loadFuture = operation;
    return operation.whenComplete(() {
      if (identical(_loadFuture, operation)) _loadFuture = null;
    });
  }

  Future<void> _loadInternal() async {
    _setState(BodyTimelineContextStatus.loading, error: null);
    JournalService? service;
    try {
      service = await _serviceFactory();
      await service.init();
      final snapshot = await service.loadContextForDay(_now());
      _context = snapshot;
      _loaded = true;
      _setState(
        snapshot.timeline.isEmpty
            ? BodyTimelineContextStatus.empty
            : BodyTimelineContextStatus.ready,
        error: null,
      );
    } on Object {
      _context = null;
      _loaded = false;
      _setState(
        BodyTimelineContextStatus.error,
        error: 'Could not load local body context. Try again.',
      );
    } finally {
      try {
        await service?.close();
      } on Object {
        // Closing is best-effort. The records are local and no connection is
        // retained after the foreground operation completes.
      }
    }
  }

  void _setState(BodyTimelineContextStatus next, {String? error}) {
    _status = next;
    _error = error;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
