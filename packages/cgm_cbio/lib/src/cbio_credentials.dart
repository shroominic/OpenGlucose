/// Caller-supplied vendor material for the authenticated GS1 link.
///
/// This repository supplies no real vendor-material defaults. The RC4 key,
/// the 16-byte link credential carried inside the authentication frame, and the
/// five-byte sensor authentication prompt are supplied from outside the
/// repository. The define source uses compile-time constants, so configured
/// builds embed those values; caller-injected map/static sources are separate
/// mechanisms. Entry points fail closed when values are absent or malformed.
///
/// The extraction procedure and the artifact digests are recorded in
/// `docs/testing/cbio-gs1-auth-material.md`. That record deliberately does not
/// restate the bytes, and neither does any file under `packages/cgm_cbio`.
library;

/// Build-time or environment variable holding the 16-byte RC4 stream key.
const String cbioStreamKeyDefine = 'CBIO_VENDOR_STREAM_KEY_HEX';

/// Build-time or environment variable holding the 16-byte link credential.
const String cbioAuthMaterialDefine = 'CBIO_VENDOR_AUTH_MATERIAL_HEX';

/// Build-time or environment variable holding the five-byte auth prompt.
const String cbioAuthTriggerDefine = 'CBIO_VENDOR_AUTH_TRIGGER_HEX';

/// The stream key as passed to the compiler, or the empty string.
const String cbioStreamKeyHex = String.fromEnvironment(cbioStreamKeyDefine);

/// The link credential as passed to the compiler, or the empty string.
const String cbioAuthMaterialHex = String.fromEnvironment(
  cbioAuthMaterialDefine,
);

/// The authentication prompt as passed to the compiler, or the empty string.
const String cbioAuthTriggerHex = String.fromEnvironment(cbioAuthTriggerDefine);

/// Raised when the vendor material is not configured for this process.
///
/// Callers must treat this as a fail-closed condition: no frame is built, no
/// link is opened, and the reason is reported to the user as a configuration
/// problem rather than a sensor problem.
final class CbioCredentialUnavailable implements Exception {
  /// Creates the error with the variable or step that was missing.
  const CbioCredentialUnavailable(this.message);

  /// What was missing, or why the supplied value was rejected.
  final String message;

  @override
  String toString() => 'CbioCredentialUnavailable: $message';
}

/// The three vendor values one authenticated GS1 link needs.
///
/// The value is immutable, and its [toString] never renders any byte, so it is
/// safe to hold in a session object and to appear in a log line or an error.
final class CbioCredentials {
  /// Validates and defensively copies one set of vendor material.
  CbioCredentials({
    required List<int> streamKey,
    required List<int> authMaterial,
    required List<int> authenticationTrigger,
  }) : streamKey = _checked(streamKey, streamKeyLength, 'streamKey'),
       authMaterial = _checked(
         authMaterial,
         authMaterialLength,
         'authMaterial',
       ),
       authenticationTrigger = _checked(
         authenticationTrigger,
         authenticationTriggerLength,
         'authenticationTrigger',
       );

  /// Parses one set of vendor material from hex.
  ///
  /// Whitespace, colons, and hyphens are ignored, so a value copied out of a
  /// hex dump or a hardware debugger paste is accepted. Any other character, an
  /// odd digit count, or a wrong byte count is an [ArgumentError].
  factory CbioCredentials.fromHex({
    required String streamKey,
    required String authMaterial,
    required String authenticationTrigger,
  }) => CbioCredentials(
    streamKey: _unhex(streamKey, 'streamKey'),
    authMaterial: _unhex(authMaterial, 'authMaterial'),
    authenticationTrigger: _unhex(
      authenticationTrigger,
      'authenticationTrigger',
    ),
  );

  /// Required byte count of [streamKey].
  static const int streamKeyLength = 16;

  /// Required byte count of [authMaterial].
  static const int authMaterialLength = 16;

  /// Required byte count of [authenticationTrigger].
  static const int authenticationTriggerLength = 5;

  /// The 16-byte per-frame stream key. Never log or transmit this value.
  final List<int> streamKey;

  /// The 16-byte link credential the authentication frame carries.
  final List<int> authMaterial;

  /// The five masked bytes the sensor sends when it wants authentication.
  ///
  /// The prompt is a sensor notification, not a credential, but it is derived
  /// from the same stream key and is injected with the rest of the material so
  /// that no real-material default is committed to this package. Values
  /// supplied through the define source are still embedded in its artifacts.
  final List<int> authenticationTrigger;

  @override
  String toString() => 'CbioCredentials(<redacted>)';

  static List<int> _checked(List<int> bytes, int expected, String name) {
    if (bytes.length != expected) {
      throw ArgumentError.value(bytes, name, 'must be exactly $expected bytes');
    }
    return List<int>.unmodifiable(bytes);
  }

  static List<int> _unhex(String value, String name) {
    final cleaned = value.replaceAll(RegExp(r'[\s:_-]'), '');
    if (cleaned.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
    if (cleaned.length.isOdd) {
      throw ArgumentError.value(value, name, 'must have an even digit count');
    }
    final bytes = <int>[];
    for (var i = 0; i < cleaned.length; i += 2) {
      final byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (byte == null) {
        throw ArgumentError.value(value, name, 'must be hexadecimal');
      }
      bytes.add(byte);
    }
    return bytes;
  }
}

/// Supplies the vendor material for one link.
///
/// Implementations are asked once per session. They must not read the material
/// from the repository, and they must not return a partially populated value.
abstract interface class CbioCredentialSource {
  /// Whether [read] can be expected to return material.
  ///
  /// A caller that needs to decide whether to register a GS1 driver at all can
  /// ask this instead of catching [CbioCredentialUnavailable] at connect time.
  bool get isConfigured;

  /// Returns the material, or throws [CbioCredentialUnavailable].
  CbioCredentials read();
}

/// Reads the material from values supplied at build time or lookup time.
///
/// The lookup is deliberately explicit: a build without the three values is a
/// build that cannot authenticate a GS1 link, and it says so instead of falling
/// back to a compiled default.
final class CbioMapCredentialSource implements CbioCredentialSource {
  /// Creates a source over one string map.
  const CbioMapCredentialSource(
    this.values, {
    this.streamKeyKey = cbioStreamKeyDefine,
    this.authMaterialKey = cbioAuthMaterialDefine,
    this.authenticationTriggerKey = cbioAuthTriggerDefine,
  });

  /// The map the three values are read from, usually a process environment.
  final Map<String, String> values;

  /// Name of the stream key entry.
  final String streamKeyKey;

  /// Name of the link credential entry.
  final String authMaterialKey;

  /// Name of the authentication prompt entry.
  final String authenticationTriggerKey;

  /// Whether all three values are present and non-empty.
  @override
  bool get isConfigured =>
      _present(streamKeyKey) &&
      _present(authMaterialKey) &&
      _present(authenticationTriggerKey);

  /// Names of the entries that are absent.
  List<String> get missing => <String>[
    if (!_present(streamKeyKey)) streamKeyKey,
    if (!_present(authMaterialKey)) authMaterialKey,
    if (!_present(authenticationTriggerKey)) authenticationTriggerKey,
  ];

  @override
  CbioCredentials read() {
    final absent = missing;
    if (absent.isNotEmpty) {
      throw CbioCredentialUnavailable(
        'GS1 vendor material is not configured: set ${absent.join(', ')}',
      );
    }
    try {
      return CbioCredentials.fromHex(
        streamKey: values[streamKeyKey]!,
        authMaterial: values[authMaterialKey]!,
        authenticationTrigger: values[authenticationTriggerKey]!,
      );
    } on ArgumentError catch (error) {
      throw CbioCredentialUnavailable(
        'GS1 vendor material is malformed: ${error.message}',
      );
    }
  }

  bool _present(String key) => (values[key] ?? '').trim().isNotEmpty;
}

/// Reads the material from `--dart-define` values compiled into the build.
///
/// ```sh
/// flutter run \
///   --dart-define=CBIO_VENDOR_STREAM_KEY_HEX=<16 bytes> \
///   --dart-define=CBIO_VENDOR_AUTH_MATERIAL_HEX=<16 bytes> \
///   --dart-define=CBIO_VENDOR_AUTH_TRIGGER_HEX=<5 bytes>
/// ```
///
/// Prefer `--dart-define-from-file` against a git-ignored local file so the
/// values never reach a shell history entry or a committed file.
final class CbioDefineCredentialSource implements CbioCredentialSource {
  /// Creates a source over the compiled defines.
  const CbioDefineCredentialSource({
    this.streamKey = cbioStreamKeyHex,
    this.authMaterial = cbioAuthMaterialHex,
    this.authenticationTrigger = cbioAuthTriggerHex,
  });

  /// Compiled stream key, or the empty string.
  final String streamKey;

  /// Compiled link credential, or the empty string.
  final String authMaterial;

  /// Compiled authentication prompt, or the empty string.
  final String authenticationTrigger;

  @override
  bool get isConfigured => CbioMapCredentialSource(<String, String>{
    cbioStreamKeyDefine: streamKey,
    cbioAuthMaterialDefine: authMaterial,
    cbioAuthTriggerDefine: authenticationTrigger,
  }).isConfigured;

  @override
  CbioCredentials read() => CbioMapCredentialSource(<String, String>{
    cbioStreamKeyDefine: streamKey,
    cbioAuthMaterialDefine: authMaterial,
    cbioAuthTriggerDefine: authenticationTrigger,
  }).read();

  @override
  String toString() => 'CbioDefineCredentialSource(<redacted>)';
}

/// Fixed material for tests and benches.
final class CbioStaticCredentialSource implements CbioCredentialSource {
  /// Creates a source that always returns [credentials].
  const CbioStaticCredentialSource(this.credentials);

  /// The material every [read] returns.
  final CbioCredentials credentials;

  @override
  bool get isConfigured => true;

  @override
  CbioCredentials read() => credentials;

  @override
  String toString() => 'CbioStaticCredentialSource(<redacted>)';
}
