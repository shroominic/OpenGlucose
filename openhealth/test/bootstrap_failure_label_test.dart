import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/bootstrap_failure_label.dart';

void main() {
  test('FileSystemException labels prefer the OS message over a path', () {
    final error = PathAccessException(
      'Creation failed',
      const OSError('Operation not permitted', 1),
      '/var/mobile/Containers/Data/Application/example/Library/Application Support',
    );

    expect(
      bootstrapFailureLabel(error),
      'PathAccessException: Operation not permitted',
    );
    expect(
      bootstrapFailureLabel(error),
      isNot(contains('Application Support')),
    );
  });

  test('StateError messages surface without a filesystem path', () {
    expect(
      bootstrapFailureLabel(
        StateError(
          'Restricted health-state storage is not writable at startup: '
          'Operation not permitted',
        ),
      ),
      contains('not writable at startup'),
    );
  });

  test('other errors keep the runtime type only', () {
    expect(bootstrapFailureLabel(FormatException('bad')), 'FormatException');
  });
}
