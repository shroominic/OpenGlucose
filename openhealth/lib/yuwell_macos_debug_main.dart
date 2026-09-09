import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openglucose/src/yuwell_macos_debug_driver.dart';
import 'package:openglucose/src/yuwell_macos_debug_session.dart';
import 'package:openglucose/src/yuwell_macos_secure_session_store.dart'
    show YuwellMacosInMemoryKeyValueStore, yuwellMacosKeychainOptions;

/// Private, debug-only entry point for the OpenGlucose Anytime 5P Mac-BLE
/// contest path.
///
/// This is intentionally separate from `main.dart` and from the Android-only
/// `OG_PROTOCOL_TRACE` capture harness (`protocol_capture_main.dart`): it
/// does not weaken either gate, and neither of them can reach macOS. Run
/// with:
///
/// ```sh
/// flutter run -d macos --debug \
///   --dart-define=OG_MACOS_YUWELL_DEBUG=true
/// ```
///
/// Add `--dart-define=OG_MACOS_YUWELL_SHOW_VALUE=true` to also echo the
/// provisional mg/dL number to this local window. It is never logged
/// otherwise. Add `--dart-define=OG_MACOS_YUWELL_AUTOSTART=true` to start the
/// bounded attempt on launch instead of waiting for a tap on the Bluetooth
/// icon — for a terminal-driven run where no one can click the window.
/// Nothing this entry point prints should be committed, attached to an
/// issue, or copied anywhere but a private, redacted evidence note — see
/// `docs/runbooks/yuwell-anytime-5p-protocol-capture.md`.
const bool _macosYuwellDebugEnabled = bool.fromEnvironment(
  'OG_MACOS_YUWELL_DEBUG',
);
const bool _macosYuwellShowValue = bool.fromEnvironment(
  'OG_MACOS_YUWELL_SHOW_VALUE',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !_macosYuwellDebugEnabled) {
    throw UnsupportedError(
      'The macOS Yuwell debug entry point requires an '
      'OG_MACOS_YUWELL_DEBUG debug build.',
    );
  }
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'This entry point currently supports macOS debug builds only.',
    );
  }
  runApp(const _YuwellMacosDebugApp());
}

final class _YuwellMacosDebugApp extends StatefulWidget {
  const _YuwellMacosDebugApp();

  @override
  State<_YuwellMacosDebugApp> createState() => _YuwellMacosDebugAppState();
}

final class _YuwellMacosDebugAppState extends State<_YuwellMacosDebugApp> {
  final List<String> _log = <String>[];
  YuwellMacosDebugOutcome? _outcome;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // Opt-in, terminal-driven path for an operator running this build
    // headlessly (no click available on the Bluetooth icon). Off by default
    // so the normal interactive build never scans without an explicit tap.
    if (const bool.fromEnvironment('OG_MACOS_YUWELL_AUTOSTART')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autostart());
    }
  }

  Future<void> _autostart() async {
    // The credential store is a plain OS Keychain read/write — it never
    // touches BLE, so it needs no GRAB/RELEASE. Check it in isolation first:
    // an ad-hoc-signed build (no Team ID) can fail every Keychain item with
    // errSecMissingEntitlement, independent of anything this app requests in
    // its own entitlements. When that's the failure, fall back to an
    // in-memory store for this run rather than lose the attempt entirely —
    // see YuwellMacosInMemoryKeyValueStore's doc comment for the trade-off.
    final keychainOk = await _selfTestKeychain();
    if (!keychainOk) {
      _appendLog(
        'Falling back to an in-memory credential/write-intent store for '
        'this run (state-machine guards unchanged; does not survive '
        'process death). Fix: sign this build with a real Team ID.',
      );
    }
    await _runAttempt(useInMemoryFallback: !keychainOk);
  }

  /// Diagnostic-only: exercises the exact Keychain options the real store
  /// uses, and logs the raw platform error on failure. This is plumbing
  /// diagnostics (an OS error code/message), never sensor or health data, so
  /// unlike the store itself it does not need to suppress the error detail.
  Future<bool> _selfTestKeychain() async {
    const storage = FlutterSecureStorage();
    const testKey = 'ct5.macos.selftest.v1';
    try {
      await storage.write(
        key: testKey,
        value: 'ok',
        mOptions: yuwellMacosKeychainOptions,
      );
      final readBack = await storage.read(
        key: testKey,
        mOptions: yuwellMacosKeychainOptions,
      );
      await storage.delete(key: testKey, mOptions: yuwellMacosKeychainOptions);
      if (readBack != 'ok') {
        _appendLog('Keychain self-test: wrote "ok", read back "$readBack".');
        return false;
      }
      _appendLog('Keychain self-test: OK.');
      return true;
    } on Object catch (error) {
      _appendLog('Keychain self-test FAILED: $error');
      return false;
    }
  }

  void _appendLog(String line) {
    // ignore: avoid_print - this window is the operator's only view of a live attempt
    print('[yuwell-macos-debug] $line');
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  Future<void> _runAttempt({bool useInMemoryFallback = false}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _outcome = null;
    });
    final outcome = await runYuwellMacosDebugAttempt(
      driver: buildYuwellMacosDebugDriver(
        keyValueStore: useInMemoryFallback
            ? YuwellMacosInMemoryKeyValueStore()
            : null,
      ),
      log: _appendLog,
      showValue: _macosYuwellShowValue,
    );
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF3F8F5),
        appBar: AppBar(
          title: const Text('Yuwell Anytime 5P — Mac BLE debug'),
          backgroundColor: const Color(0xFF0B6E69),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.bluetooth_searching_rounded),
              tooltip: 'Scan + attempt a live read',
              onPressed: _running ? null : _runAttempt,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _running
                      ? 'Attempt in progress…'
                      : outcome == null
                      ? 'Idle. Press the Bluetooth icon to attempt a bounded '
                            'scan/connect/read.'
                      : 'Last attempt: sensorFound=${outcome.sensorFound} '
                            'reading=${outcome.gotProvisionalReading} '
                            'stage=${outcome.finalStage?.name}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _log.length,
                    itemBuilder: (context, index) {
                      final line = _log[_log.length - 1 - index];
                      return Text(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
