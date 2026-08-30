import 'package:cgm_core/cgm_core.dart';

/// Opens and owns one local health repository for the app lifetime.
///
/// Feature controllers may acquire the repository but never close it. This
/// prevents a controller from caching a Sqflite instance after another feature
/// has closed it. The composition root owns [dispose] during app shutdown.
class AppHealthRepositoryLifecycle {
  AppHealthRepositoryLifecycle(this._opener);

  final Future<HealthRepository> Function() _opener;
  Future<HealthRepository>? _repositoryFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  Future<HealthRepository> acquire() async {
    if (_disposed) {
      throw StateError('The app health repository has been disposed.');
    }
    final future = _repositoryFuture ??= _opener();
    try {
      return await future;
    } on Object {
      if (identical(_repositoryFuture, future)) {
        _repositoryFuture = null;
      }
      rethrow;
    }
  }

  /// Closes the one owned repository exactly once after app teardown starts.
  Future<void> dispose() {
    return _disposeFuture ??= _disposeOnce();
  }

  Future<void> _disposeOnce() async {
    _disposed = true;
    final future = _repositoryFuture;
    if (future == null) {
      return;
    }
    try {
      final repository = await future;
      await repository.close();
    } on Object {
      // Teardown must not retain a failed opening future or surface data.
    }
  }
}
