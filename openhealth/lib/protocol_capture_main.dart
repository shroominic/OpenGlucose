import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:openglucose/src/driver_factory.dart';

const bool _protocolTraceEnabled = bool.fromEnvironment('OG_PROTOCOL_TRACE');
const String _captureProfile = String.fromEnvironment(
  'OG_PROTOCOL_CAPTURE_PROFILE',
  defaultValue: 'libre',
);

/// Minimal debug-only entry point for passive protocol evidence collection.
///
/// It deliberately does not construct the application controller or any live
/// sensor driver. [configurePlatformPrivacyDefaults] starts the reviewed
/// observation-only recorder, whose driver cannot discover or connect.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !_protocolTraceEnabled) {
    throw UnsupportedError(
      'The protocol-capture entry point requires an OG_PROTOCOL_TRACE '
      'Android debug build.',
    );
  }
  await configurePlatformPrivacyDefaults();
  runApp(const _ProtocolCaptureApp());
}

final class _ProtocolCaptureApp extends StatelessWidget {
  const _ProtocolCaptureApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF3F8F5),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: const Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.bluetooth_searching_rounded,
                      size: 52,
                      color: Color(0xFF0B6E69),
                    ),
                    SizedBox(height: 18),
                    Text(
                      'Passive protocol capture',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Profile: $_captureProfile\n\n'
                      'This debug surface records advertisements only. It '
                      'cannot select, connect to, activate, pair, or write to '
                      'a sensor. Keep the app in the foreground and use the '
                      'private host capture runbook.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
