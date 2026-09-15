import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_nfc_history_pane.dart';
import 'package:openglucose/src/libre_nfc_history_sync.dart';
import 'package:openglucose/src/libre_nfc_history_tools.dart';

const _sensor = DiscoveredSensor(
  driverId: 'libre2-gen1',
  deviceId: '02:00:00:00:00:01',
  displayName: 'Synthetic private sensor',
  storageKey: 'libre2-gen1:synthetic_receiver_1234',
  rssi: -50,
  capabilities: CgmCapabilities(),
);

LibreGen1StreamingBootstrap _bootstrap() => LibreGen1StreamingBootstrap(
  bootstrapId: 'synthetic_receiver_1234',
  deviceId: _sensor.deviceId,
  uid: LibreGen1Uid.algorithmOrder([1, 2, 3, 4, 5, 6, 7, 0xe0]),
  initialPatchInfo: LibreGen1PatchInfo([0x9d, 8, 0x30, 1, 0x34, 0x12]),
  streamingBase: 0,
  lifecycle: LibreGen1LifecycleState.active,
);

void main() {
  late _Harness h;
  setUp(() => h = _Harness());

  Future<void> show(
    WidgetTester tester, {
    bool reducedMotion = false,
    double textScale = 1,
    bool cleanupBlocked = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: LibreNfcHistoryPane(
                  sensor: _sensor,
                  tools: h.tools,
                  cleanupBlocked: cleanupBlocked,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1));
    // Stream cancellation can return an SDK cached future created outside
    // FakeAsync. Drain only that root-zone turn; never await a fake timer here.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> start(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('syncLibreHistory')));
    await tester.tap(find.byKey(const ValueKey('syncLibreHistory')));
    await flush(tester);
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  }

  testWidgets('showing the panel performs no bootstrap or NFC work', (
    tester,
  ) async {
    await show(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(h.created, 0);
    expect(h.bootstrapReads, 0);
    expect(
      find.text('Tap your sensor to copy up to 8 hours of stored readings.'),
      findsOneWidget,
    );
    expect(find.text(_sensor.displayName), findsNothing);
    await remove(tester);
  });

  testWidgets(
    'explicit scan shows detected and import states, then a historical count',
    (tester) async {
      await show(tester);
      await start(tester);
      final sync = h.syncs.single;
      expect(h.bootstrapReads, 1);
      expect(sync.starts, 1);
      expect(
        find.text('Hold the back of your phone against the sensor.'),
        findsOneWidget,
      );
      sync.emit(LibreNfcHistorySyncPhase.reading);
      await flush(tester);
      expect(
        find.text('Sensor detected. Reading stored data…'),
        findsOneWidget,
      );
      sync.emit(LibreNfcHistorySyncPhase.importing);
      await flush(tester);
      expect(find.text('Saving missing readings…'), findsOneWidget);
      sync.complete(3);
      await flush(tester);
      expect(
        find.text(
          '3 readings added to history. Reconnect to resume live readings.',
        ),
        findsOneWidget,
        reason:
            '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}; cancel=${sync.cancels}/${sync.cancelSettled} dispose=${sync.disposals}/${sync.disposeSettled}',
      );
      expect(sync.disposals, 1);
      expect(find.text('Connected'), findsNothing);
      expect(find.textContaining('mg/dL'), findsNothing);
      expect(sync.starts, 1);
      await remove(tester);
    },
  );

  testWidgets('zero import does not claim all data is available or live', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    h.syncs.single.complete(0);
    await flush(tester);
    expect(
      find.text(
        'No new readings were added. Reconnect to resume live readings.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('up to date'), findsNothing);
    expect(h.created, 1);
    await remove(tester);
  });

  testWidgets('cancel revokes immediately and waits cleanup before retry', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    sync.cancelGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('cancelLibreHistory')));
    expect(sync.cancels, 1);
    await flush(tester);
    expect(find.text('Stopping…'), findsOneWidget);
    expect(find.byKey(const ValueKey('syncLibreHistory')), findsNothing);
    expect(sync.disposals, 0);
    sync.cancelGate!.complete();
    await flush(tester);
    expect(sync.disposals, 1);
    expect(
      find.text('History sync stopped. Reconnect to resume live readings.'),
      findsOneWidget,
    );
    await start(tester);
    expect(h.created, 2);
    expect(h.syncs.last.starts, 1);
    await remove(tester);
  });

  testWidgets('disposal cancels active work and absorbs late results', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    sync.cancelGate = Completer<void>();
    await remove(tester);
    expect(sync.cancels, 1);
    expect(sync.disposals, 0);
    sync.complete(2);
    sync.cancelGate!.complete();
    await flush(tester);
    expect(sync.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposal before bootstrap completion cannot start a late scan', (
    tester,
  ) async {
    final bootstrap = Completer<LibreGen1StreamingBootstrap?>();
    h.read = () => bootstrap.future;
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    expect(sync.starts, 0);
    await remove(tester);
    expect(sync.cancels, 1);
    expect(sync.disposals, 1);
    bootstrap.complete(_bootstrap());
    await flush(tester);
    expect(sync.starts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding cancels and resume never starts automatically', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(sync.cancels, 1);
    await flush(tester);
    expect(sync.disposals, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(h.created, 1);
    expect(sync.starts, 1);
    await remove(tester);
  });

  for (final throwsOnDispose in [false, true]) {
    testWidgets('uncertain disposal blocks retry (throws=$throwsOnDispose)', (
      tester,
    ) async {
      await show(tester);
      await start(tester);
      final sync = h.syncs.single;
      sync.disposeFails = throwsOnDispose;
      sync.cleanupUnconfirmed = !throwsOnDispose;
      sync.complete(3);
      await flush(tester);
      expect(
        find.textContaining('Sensor cleanup could not be confirmed.'),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('syncLibreHistory')),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('3 readings added'), findsNothing);
      expect(h.created, 1);
      expect(tester.takeException(), isNull);
      await remove(tester);
    });
  }

  testWidgets('successful count waits for asynchronous disposal', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    sync.disposeGate = Completer<void>();
    sync.complete(1);
    await flush(tester);
    expect(find.text('Finishing history sync…'), findsOneWidget);
    expect(find.byKey(const ValueKey('syncLibreHistory')), findsNothing);
    sync.disposeGate!.complete();
    await flush(tester);
    expect(
      find.text(
        '1 reading added to history. Reconnect to resume live readings.',
      ),
      findsOneWidget,
    );
    await remove(tester);
  });

  testWidgets('unknown errors have closed text and no leaked details', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    h.syncs.single.completion.completeError(
      StateError('synthetic-private-detail'),
    );
    await flush(tester);
    expect(
      find.text(
        'Could not copy stored readings. Check the sensor and try again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('synthetic-private-detail'), findsNothing);
    expect(tester.takeException(), isNull);
    await remove(tester);
  });

  testWidgets('missing bootstrap never starts a scan', (tester) async {
    h.read = () async => null;
    await show(tester);
    await start(tester);
    expect(h.syncs.single.starts, 0);
    expect(h.syncs.single.disposals, 1);
    expect(
      find.textContaining('Could not copy stored readings.'),
      findsOneWidget,
    );
    await remove(tester);
  });

  testWidgets('scan animation stops when reduced motion is enabled', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<Opacity>(find.byKey(const ValueKey('libreHistoryScanPulse')))
          .opacity,
      lessThan(1),
    );
    await show(tester, reducedMotion: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<Opacity>(find.byKey(const ValueKey('libreHistoryScanPulse')))
          .opacity,
      1,
    );
    expect(h.created, 1);
    await remove(tester);
  });

  testWidgets(
    'successful sync resumes Bluetooth only after confirmed disposal',
    (
      tester,
    ) async {
      h.resume = () async {};
      await show(tester);
      expect(find.text('Resume Bluetooth'), findsNothing);
      await start(tester);
      final sync = h.syncs.single;
      sync.disposeGate = Completer<void>();
      sync.complete(1);
      await flush(tester);
      expect(h.resumes, 0);
      expect(find.text('Resume Bluetooth'), findsNothing);
      sync.disposeGate!.complete();
      await flush(tester);
      expect(h.resumes, 1);
      expect(find.text('1 reading added to history.'), findsOneWidget);
      expect(find.text('Resume Bluetooth'), findsNothing);
      expect(find.text('Connected'), findsNothing);
      await remove(tester);
    },
  );

  testWidgets('uncertain cleanup cannot offer Bluetooth resume', (
    tester,
  ) async {
    h.resume = () async {};
    await show(tester);
    await start(tester);
    h.syncs.single.cleanupUnconfirmed = true;
    h.syncs.single.complete(0);
    await flush(tester);
    expect(find.text('Resume Bluetooth'), findsNothing);
    expect(h.resumes, 0);
    await remove(tester);
  });

  testWidgets(
    'automatic resume shows progress and cannot overlap another sync',
    (
      tester,
    ) async {
      final resumed = Completer<void>();
      h.resume = () => resumed.future;
      await show(tester);
      await start(tester);
      h.syncs.single.complete(43);
      await flush(tester);
      expect(h.resumes, 1);
      expect(
        find.text('43 readings added to history. Reconnecting Bluetooth…'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('syncLibreHistory')),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(h.resumes, 1);
      expect(find.text('Connected'), findsNothing);
      resumed.complete();
      await flush(tester);
      expect(find.text('43 readings added to history.'), findsOneWidget);
      await remove(tester);
    },
  );

  for (final boundary in ['background', 'route', 'quarantine', 'tools']) {
    testWidgets('no automatic resume after $boundary during cleanup', (
      tester,
    ) async {
      h.resume = () async {};
      await show(tester);
      await start(tester);
      final sync = h.syncs.single;
      sync.disposeGate = Completer<void>();
      sync.complete(2);
      await flush(tester);
      final original = h;
      switch (boundary) {
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        case 'route':
          await remove(tester);
        case 'quarantine':
          await show(tester, cleanupBlocked: true);
        case 'tools':
          h = _Harness()..resume = () async {};
          await show(tester);
      }
      sync.disposeGate!.complete();
      await flush(tester);
      expect(original.resumes, 0);
      expect(h.resumes, 0);
      if (boundary == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await flush(tester);
        expect(h.resumes, 0);
      }
      await remove(tester);
    });
  }

  testWidgets('an invalid imported count cannot trigger automatic resume', (
    tester,
  ) async {
    h.resume = () async {};
    await show(tester);
    await start(tester);
    h.syncs.single.complete(49);
    await flush(tester);
    expect(h.resumes, 0);
    expect(find.text('History sync could not be confirmed.'), findsOneWidget);
    await remove(tester);
  });

  testWidgets('cancelled scan offers resume but does not call it', (
    tester,
  ) async {
    h.resume = () async {};
    await show(tester);
    await start(tester);
    await tester.tap(find.text('Cancel'));
    await flush(tester);
    expect(find.text('Resume Bluetooth'), findsOneWidget);
    expect(h.resumes, 0);
    await remove(tester);
  });

  testWidgets('resume failure is closed and does not claim connection', (
    tester,
  ) async {
    h.resume = () async => throw StateError('synthetic-private-resume-error');
    await show(tester);
    await start(tester);
    h.syncs.single.complete(0);
    await flush(tester);
    expect(h.resumes, 1);
    expect(find.text('Could not resume Bluetooth. Try again.'), findsOneWidget);
    expect(find.textContaining('synthetic-private-resume-error'), findsNothing);
    expect(find.text('Connected'), findsNothing);
    expect(tester.takeException(), isNull);
    await remove(tester);
  });

  testWidgets(
    'external cleanup quarantine performs no eager work and disables retry',
    (tester) async {
      await show(tester, cleanupBlocked: true);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('syncLibreHistory')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('Sensor cleanup could not be confirmed.'),
        findsOneWidget,
      );
      expect(h.created, 0);
      expect(h.bootstrapReads, 0);
      await remove(tester);
    },
  );

  testWidgets('synchronous cancel error cannot enter cleanup twice', (
    tester,
  ) async {
    await show(tester);
    await start(tester);
    final sync = h.syncs.single;
    sync.reenterOnCancel = true;
    await tester.tap(find.text('Cancel'));
    await flush(tester);
    expect(sync.cancels, 1);
    expect(sync.disposals, 1);
    expect(
      find.text('History sync stopped. Reconnect to resume live readings.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await remove(tester);
  });

  testWidgets('confirmed clean failure offers only explicit Bluetooth resume', (
    tester,
  ) async {
    h.resume = () async {};
    await show(tester);
    await start(tester);
    h.syncs.single.completion.complete(
      const LibreNfcHistorySyncState(
        LibreNfcHistorySyncPhase.failed,
        failure: LibreNfcHistorySyncFailure.readFailed,
      ),
    );
    await flush(tester);
    expect(find.text('Resume Bluetooth'), findsOneWidget);
    expect(h.resumes, 0);
    expect(h.syncs.single.disposals, 1);
    await remove(tester);
  });

  testWidgets('late bootstrap cannot affect the next explicit attempt', (
    tester,
  ) async {
    final firstBootstrap = Completer<LibreGen1StreamingBootstrap?>();
    h.read = () => h.bootstrapReads == 1
        ? firstBootstrap.future
        : Future.value(_bootstrap());
    await show(tester);
    await start(tester);
    await tester.tap(find.text('Cancel'));
    await flush(tester);
    expect(h.syncs.single.disposals, 1);
    await start(tester);
    expect(h.created, 2);
    firstBootstrap.complete(_bootstrap());
    await flush(tester);
    expect(h.syncs.first.starts, 0);
    expect(h.syncs.last.starts, 1);
    expect(
      find.text('Hold the back of your phone against the sensor.'),
      findsOneWidget,
    );
    await remove(tester);
  });

  testWidgets('large text wraps and progress is a semantic live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester, reducedMotion: true, textScale: 3);
    await start(tester);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await remove(tester);
    semantics.dispose();
  });
}

class _Harness {
  int created = 0;
  int bootstrapReads = 0;
  int resumes = 0;
  Future<void> Function()? resume;
  final syncs = <_Sync>[];
  Future<LibreGen1StreamingBootstrap?> Function() read = () async =>
      _bootstrap();
  late final tools = LibreNfcHistoryTools(
    createSync: () {
      created++;
      final sync = _Sync();
      syncs.add(sync);
      return sync;
    },
    readBootstrap: () {
      bootstrapReads++;
      return read();
    },
    resumeConnection: resume == null
        ? null
        : (sensor) async {
            expect(sensor, _sensor);
            resumes++;
            await resume!();
          },
  );
}

class _Sync implements LibreNfcHistorySyncController {
  final _states = StreamController<LibreNfcHistorySyncState>.broadcast(
    sync: true,
  );
  final completion = Completer<LibreNfcHistorySyncState>();
  int starts = 0;
  int cancels = 0;
  int disposals = 0;
  bool disposeFails = false;
  bool reenterOnCancel = false;
  bool cancelSettled = false;
  bool disposeSettled = false;
  Completer<void>? cancelGate;
  Completer<void>? disposeGate;
  @override
  bool cleanupUnconfirmed = false;
  @override
  LibreNfcHistorySyncState state = const LibreNfcHistorySyncState(
    LibreNfcHistorySyncPhase.idle,
  );
  @override
  Stream<LibreNfcHistorySyncState> get states => _states.stream;
  void emit(LibreNfcHistorySyncPhase phase) {
    state = LibreNfcHistorySyncState(phase);
    _states.add(state);
  }

  void complete(int count) {
    state = LibreNfcHistorySyncState(
      LibreNfcHistorySyncPhase.completed,
      importedReadingCount: count,
    );
    _states.add(state);
    completion.complete(state);
  }

  @override
  Future<LibreNfcHistorySyncState> sync({
    required DiscoveredSensor sensor,
    required LibreGen1StreamingBootstrap bootstrap,
  }) {
    starts++;
    expect(sensor, _sensor);
    expect(bootstrap.bootstrapId, 'synthetic_receiver_1234');
    emit(LibreNfcHistorySyncPhase.listening);
    return completion.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (reenterOnCancel) {
      reenterOnCancel = false;
      _states.addError(StateError('synthetic synchronous cancellation error'));
    }
    await cancelGate?.future;
    if (!completion.isCompleted) {
      completion.complete(
        const LibreNfcHistorySyncState(LibreNfcHistorySyncPhase.cancelled),
      );
    }
    cancelSettled = true;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await disposeGate?.future;
    await _states.close();
    if (disposeFails) throw StateError('synthetic-private-stop-detail');
    disposeSettled = true;
  }
}
