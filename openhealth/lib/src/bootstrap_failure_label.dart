import 'dart:io' show FileSystemException;

/// Identifier-free bootstrap failure label for the splash screen.
///
/// Prefer the OS error message over a filesystem path so install/container
/// identifiers never appear in the first-run failure surface.
String bootstrapFailureLabel(Object error) {
  if (error is FileSystemException) {
    final message = error.osError?.message.trim();
    if (message != null && message.isNotEmpty) {
      return '${error.runtimeType}: $message';
    }
  }
  if (error is StateError) {
    final message = error.message.trim();
    if (message.isNotEmpty) {
      return message;
    }
  }
  return error.runtimeType.toString();
}
