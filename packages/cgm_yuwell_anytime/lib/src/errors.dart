/// A redacted error for malformed or unsupported Yuwell protocol input.
final class YuwellProtocolFormatException implements FormatException {
  const YuwellProtocolFormatException(this.message);

  @override
  final String message;

  @override
  dynamic get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => 'YuwellProtocolFormatException: $message';
}
