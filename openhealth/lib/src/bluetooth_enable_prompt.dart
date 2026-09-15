import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An explicit request to enable the phone radio, not to pair/reset a sensor.
Future<String> requestBluetoothEnable() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return 'settings';
  }
  try {
    return await const MethodChannel(
          'com.openglucose/bluetooth',
        ).invokeMethod<String>('requestEnable') ??
        'unavailable';
  } on PlatformException {
    return 'unavailable';
  } on MissingPluginException {
    return 'unavailable';
  }
}

class BluetoothEnablePrompt extends StatefulWidget {
  const BluetoothEnablePrompt({
    super.key,
    required this.onEnabled,
    this.dark = false,
  });

  final Future<void> Function() onEnabled;
  final bool dark;

  @override
  State<BluetoothEnablePrompt> createState() => _BluetoothEnablePromptState();
}

class _BluetoothEnablePromptState extends State<BluetoothEnablePrompt>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _enabled = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_continue());
  }

  Future<void> _continue() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        !_enabled ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    _enabled = false;
    try {
      if (ModalRoute.of(context)?.isCurrent ?? true) await widget.onEnabled();
    } catch (_) {
      if (mounted) setState(() => _result = 'unavailable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await requestBluetoothEnable();
    if (!mounted) return;
    setState(() {
      _result = result;
      _enabled = result == 'enabled';
      _busy = _enabled;
    });
    await _continue();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final message = switch (_result) {
      'permissionRequired' =>
        'Allow Nearby devices in OpenGlucose app settings, then turn on Bluetooth.',
      'unavailable' ||
      'settings' => 'Turn on Bluetooth in your phone settings, then continue.',
      _ => 'Turn on Bluetooth to receive sensor readings.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: widget.dark ? const Color(0xFFD6ECE7) : null),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          key: const ValueKey('enableBluetoothButton'),
          onPressed: _busy
              ? null
              : android
              ? _request
              : widget.onEnabled,
          icon: const Icon(Icons.bluetooth_rounded),
          label: Text(
            _busy
                ? 'Please wait…'
                : android
                ? 'Turn on Bluetooth'
                : 'Continue',
          ),
        ),
      ],
    );
  }
}
