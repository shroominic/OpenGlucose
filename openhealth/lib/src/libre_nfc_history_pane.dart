import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'libre_nfc_history_sync.dart';
import 'libre_nfc_history_tools.dart';

/// An explicit history action, not a connection or live-reading surface.
class LibreNfcHistoryPane extends StatefulWidget {
  const LibreNfcHistoryPane({
    super.key,
    required this.sensor,
    required this.tools,
    this.cleanupBlocked = false,
    this.onClose,
    this.startImmediately = false,
  });

  final DiscoveredSensor sensor;
  final LibreNfcHistoryTools tools;
  final bool cleanupBlocked;
  final VoidCallback? onClose;
  // Only set by a route opened from an explicit Scan history button.
  final bool startImmediately;

  @override
  State<LibreNfcHistoryPane> createState() => _LibreNfcHistoryPaneState();
}

class _LibreNfcHistoryPaneState extends State<LibreNfcHistoryPane>
    with WidgetsBindingObserver {
  _PaneAttempt? _attempt;
  bool _busy = false;
  bool _blocked = false;
  bool _resuming = false;
  bool _resumeRequested = false;
  bool _resumeFailed = false;
  bool _resetAfterCleanup = false;
  bool _foreground = true;
  bool get _effectiveBlocked => _blocked || widget.cleanupBlocked;
  LibreNfcHistorySyncState _state = const LibreNfcHistorySyncState(
    LibreNfcHistorySyncPhase.idle,
  );

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (widget.startImmediately) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_start());
      });
    }
  }

  @override
  void didUpdateWidget(covariant LibreNfcHistoryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.cleanupBlocked && widget.cleanupBlocked) {
      unawaited(_cancel());
    }
    if (oldWidget.sensor.driverId != widget.sensor.driverId ||
        oldWidget.sensor.deviceId != widget.sensor.deviceId ||
        oldWidget.sensor.storageKey != widget.sensor.storageKey ||
        !identical(oldWidget.tools, widget.tools)) {
      _resetAfterCleanup = true;
      unawaited(_cancel());
      if (_attempt == null && !_effectiveBlocked) _resetForTarget();
    }
  }

  void _resetForTarget() {
    _resetAfterCleanup = false;
    _resumeRequested = false;
    _resumeFailed = false;
    _state = const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.idle);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) unawaited(_cancel());
  }

  Future<void> _start() async {
    if (!_foreground || _busy || _effectiveBlocked || _resuming) return;
    setState(() {
      _busy = true;
      _resumeRequested = false;
      _resumeFailed = false;
      _state = const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.pausing);
    });
    _PaneAttempt? attempt;
    try {
      final tools = widget.tools;
      final sensor = widget.sensor;
      attempt = _PaneAttempt(tools.createSync());
      _attempt = attempt;
      attempt.subscription = attempt.sync.states.listen(
        (state) {
          if (mounted && identical(_attempt, attempt) && !attempt!.cancelled) {
            setState(() => _state = state);
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_attempt, attempt)) unawaited(_cancel());
        },
      );
      final bootstrap = await tools.readBootstrap().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted || !identical(_attempt, attempt) || attempt.cancelled) {
        return;
      }
      if (bootstrap == null) {
        _state = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.failed,
          failure: LibreNfcHistorySyncFailure.unavailable,
        );
        return;
      }
      final result = await attempt.sync.sync(
        sensor: sensor,
        bootstrap: bootstrap,
      );
      if (mounted && identical(_attempt, attempt) && !attempt.cancelled) {
        setState(() => _state = result);
      }
    } catch (_) {
      if (mounted && (attempt == null || identical(_attempt, attempt))) {
        setState(() {
          _state = const LibreNfcHistorySyncState(
            LibreNfcHistorySyncPhase.failed,
            failure: LibreNfcHistorySyncFailure.unavailable,
          );
        });
      }
    } finally {
      if (attempt != null) {
        await _close(attempt);
      } else if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancel() {
    final attempt = _attempt;
    if (attempt == null) return Future<void>.value();
    attempt.cancelled = true;
    if (mounted) {
      setState(() {
        _state = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.stopping,
        );
      });
    }
    return _close(attempt);
  }

  bool get _canResume =>
      _foreground &&
      !_busy &&
      !_effectiveBlocked &&
      !_resumeRequested &&
      widget.tools.resumeConnection != null &&
      (_state.phase == LibreNfcHistorySyncPhase.completed ||
          _state.phase == LibreNfcHistorySyncPhase.cancelled ||
          _state.phase == LibreNfcHistorySyncPhase.failed);

  Future<void> _resume() async {
    if (!_canResume || _resuming) return;
    final tools = widget.tools;
    final sensor = widget.sensor;
    bool isCurrent() =>
        mounted &&
        identical(widget.tools, tools) &&
        widget.sensor.driverId == sensor.driverId &&
        widget.sensor.deviceId == sensor.deviceId &&
        widget.sensor.storageKey == sensor.storageKey;
    setState(() {
      _resuming = true;
      _resumeFailed = false;
    });
    try {
      await tools.resumeConnection!(sensor);
      if (isCurrent()) setState(() => _resumeRequested = true);
    } catch (_) {
      if (isCurrent()) setState(() => _resumeFailed = true);
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  Future<void> _close(_PaneAttempt attempt) {
    final pending = attempt.closing;
    if (pending != null) return pending;
    final completion = Completer<void>();
    // Install before cancel can synchronously emit an error and re-enter.
    attempt.closing = completion.future;
    unawaited(
      _finishClose(attempt).then<void>(
        (_) {
          completion.complete();
        },
        onError: (Object _, StackTrace _) {
          if (mounted && identical(_attempt, attempt)) {
            setState(() {
              _attempt = null;
              _busy = false;
              _blocked = true;
              _state = const LibreNfcHistorySyncState(
                LibreNfcHistorySyncPhase.failed,
                failure: LibreNfcHistorySyncFailure.cleanupUnconfirmed,
              );
            });
          }
          completion.complete();
        },
      ),
    );
    return completion.future;
  }

  Future<void> _finishClose(_PaneAttempt attempt) async {
    var failed = false;
    // cancel revokes synchronously; its future is the real cleanup barrier.
    try {
      await attempt.sync.cancel();
    } catch (_) {
      failed = true;
    }
    try {
      await attempt.subscription?.cancel();
    } catch (_) {
      failed = true;
    }
    try {
      await attempt.sync.dispose();
    } catch (_) {
      failed = true;
    }
    failed = failed || attempt.sync.cleanupUnconfirmed;
    if (!identical(_attempt, attempt)) return;
    _attempt = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _blocked =
          _blocked ||
          failed ||
          _state.failure == LibreNfcHistorySyncFailure.cleanupUnconfirmed;
      if (_blocked) {
        _state = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.failed,
          failure: LibreNfcHistorySyncFailure.cleanupUnconfirmed,
        );
      } else if (_resetAfterCleanup) {
        _resetForTarget();
      } else if (attempt.cancelled) {
        _state = const LibreNfcHistorySyncState(
          LibreNfcHistorySyncPhase.cancelled,
        );
      }
    });
    // The user's successful sync includes return to BLE, but only after every
    // native/durable cleanup barrier. No replay on cancel, background, target
    // change, failed import, or uncertain cleanup; those remain explicit actions.
    final count = _state.importedReadingCount;
    if (!attempt.cancelled &&
        _state.phase == LibreNfcHistorySyncPhase.completed &&
        count != null &&
        count >= 0 &&
        count <= 48 &&
        _canResume) {
      unawaited(_resume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final attempt = _attempt;
    if (attempt != null) {
      attempt.cancelled = true;
      unawaited(_close(attempt));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = _state.phase;
    final scanning =
        _busy &&
        (phase == LibreNfcHistorySyncPhase.listening ||
            phase == LibreNfcHistorySyncPhase.reading);
    final message = _message();
    return PopScope<void>(
      canPop: !_busy && !_resuming,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Stored sensor history',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: 'Close history sync',
                  onPressed: _busy || _resuming ? null : widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ScanIndicator(scanning: scanning),
                const SizedBox(width: 12),
                Expanded(child: Text(message)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_busy)
            TextButton(
              key: const ValueKey('cancelLibreHistory'),
              onPressed: _attempt?.cancelled == true
                  ? null
                  : () => unawaited(_cancel()),
              child: Text(_attempt?.cancelled == true ? 'Stopping…' : 'Cancel'),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('syncLibreHistory'),
                  onPressed: _effectiveBlocked || _resuming
                      ? null
                      : () => unawaited(_start()),
                  icon: const Icon(Icons.nfc_rounded),
                  label: const Text('Sync missing history'),
                ),
                if (_canResume)
                  OutlinedButton(
                    key: const ValueKey('resumeLibreHistoryBluetooth'),
                    onPressed: _resuming ? null : () => unawaited(_resume()),
                    child: Text(_resuming ? 'Resuming…' : 'Resume Bluetooth'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _message() {
    if (_effectiveBlocked) {
      return 'Sensor cleanup could not be confirmed. Close and reopen OpenGlucose before trying again.';
    }
    if (_resumeFailed) return 'Could not resume Bluetooth. Try again.';
    if (_busy) {
      return switch (_state.phase) {
        LibreNfcHistorySyncPhase.listening =>
          'Hold the back of your phone against the sensor.',
        LibreNfcHistorySyncPhase.reading =>
          'Sensor detected. Reading stored data…',
        LibreNfcHistorySyncPhase.stopping => 'Stopping the sensor scan…',
        LibreNfcHistorySyncPhase.decoding => 'Checking stored readings…',
        LibreNfcHistorySyncPhase.importing => 'Saving missing readings…',
        LibreNfcHistorySyncPhase.completed ||
        LibreNfcHistorySyncPhase.cancelled ||
        LibreNfcHistorySyncPhase.failed => 'Finishing history sync…',
        _ => 'Preparing the sensor scan…',
      };
    }
    if (_state.failure == LibreNfcHistorySyncFailure.cleanupUnconfirmed) {
      return 'Sensor cleanup could not be confirmed. Close and reopen OpenGlucose before trying again.';
    }
    final resumeHint = _resuming
        ? ' Reconnecting Bluetooth…'
        : _resumeRequested
        ? ''
        : ' Reconnect to resume live readings.';
    return switch (_state.phase) {
      LibreNfcHistorySyncPhase.completed =>
        switch (_state.importedReadingCount) {
          0 => 'No new readings were added.$resumeHint',
          1 => '1 reading added to history.$resumeHint',
          final int count when count > 1 && count <= 48 =>
            '$count readings added to history.$resumeHint',
          _ => 'History sync could not be confirmed.',
        },
      LibreNfcHistorySyncPhase.cancelled => 'History sync stopped.$resumeHint',
      LibreNfcHistorySyncPhase.failed =>
        'Could not copy stored readings. Check the sensor and try again.',
      _ => 'Tap your sensor to copy up to 8 hours of stored readings.',
    };
  }
}

class _PaneAttempt {
  _PaneAttempt(this.sync);
  final LibreNfcHistorySyncController sync;
  // The pane's idempotent _close cancels this after native cleanup settles.
  // ignore: cancel_subscriptions
  StreamSubscription<LibreNfcHistorySyncState>? subscription;
  Future<void>? closing;
  bool cancelled = false;
}

class _ScanIndicator extends StatefulWidget {
  const _ScanIndicator({required this.scanning});
  final bool scanning;
  @override
  State<_ScanIndicator> createState() => _ScanIndicatorState();
}

class _ScanIndicatorState extends State<_ScanIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updatePulse();
  }

  @override
  void didUpdateWidget(covariant _ScanIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePulse();
  }

  void _updatePulse() {
    if (widget.scanning && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) unawaited(_pulse.repeat(reverse: true));
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        key: const ValueKey('libreHistoryScanPulse'),
        opacity: 1 - _pulse.value * 0.45,
        child: child,
      ),
      child: Icon(
        Icons.nfc_rounded,
        size: 32,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }
}
