import 'package:cgm_yuwell_anytime/src/temperature_state.dart';
import 'package:test/test.dart';

void main() {
  group('CT5 temperature state', () {
    test('matches all 24 reviewed literal observations bit-for-bit', () {
      final state = YuwellCt5TemperatureState();

      void reset(int expected, String reason) {
        expect(state.reset(), expected, reason: reason);
      }

      void advance(int input, int expected, String reason) {
        expect(state.advance(input), expected, reason: reason);
      }

      reset(0x00000000, 'memory reset');
      advance(0x42040000, 0x42040000, 'call 1');
      advance(0x41e80000, 0x42000000, 'call 2');
      advance(0x41e80000, 0x41fa0000, 'call 3');
      advance(0x42040000, 0x41fd8000, 'call 4');

      reset(0x00000000, 'lower outside reset');
      advance(0x42040000, 0x42040000, 'call 5');
      advance(0x41380000, 0x41de0000, 'call 6');

      reset(0x00000000, 'lower endpoint reset');
      advance(0x42040000, 0x42040000, 'call 7');
      advance(0x41400000, 0x41de0000, 'call 8');

      reset(0x00000000, 'upper endpoint reset');
      advance(0x42040000, 0x42040000, 'call 9');
      advance(0x42400000, 0x42130000, 'call 10');

      reset(0x00000000, 'upper outside reset');
      advance(0x42040000, 0x42040000, 'call 11');
      advance(0x42420000, 0x42130000, 'call 12');

      reset(0x00000000, 'rounding reset');
      advance(0x42046666, 0x42046666, 'call 13');
      advance(0x41e9999a, 0x42008000, 'call 14');
      advance(0x41e9999a, 0x41fb2666, 'call 15');
      advance(0x42046666, 0x41fe8fff, 'call 16');

      reset(0x00000000, 'explicit reset group reset');
      advance(0x42040000, 0x42040000, 'call 17');
      advance(0x41e80000, 0x42000000, 'call 18');
      reset(0x00000000, 'call 19 reset');
      advance(0x41e80000, 0x41e80000, 'call 19');
      advance(0x42040000, 0x41f00000, 'call 20');

      reset(0x00000000, 'gap and restart group reset');
      advance(0x42040000, 0x42040000, 'call 21');
      advance(0x41e80000, 0x42000000, 'call 22');
      reset(0x00000000, 'call 23 invalidate');
      advance(0x41e80000, 0x41e80000, 'call 24');
    });

    test('clamps below and above the reachable domain', () {
      final state = YuwellCt5TemperatureState();

      expect(state.advance(0x41380000), 0x41400000);
      state.reset();
      expect(state.advance(0x42420000), 0x42400000);
    });

    test('rounds each binary32 operation separately', () {
      final state = YuwellCt5TemperatureState();
      state.advance(0x42046666);
      state.advance(0x41e9999a);
      state.advance(0x41e9999a);

      expect(state.advance(0x42046666), 0x41fe8fff);
      expect(0x41fe8fff, isNot(0x41fe9000));
    });

    test('instances own independent state', () {
      final first = YuwellCt5TemperatureState();
      final second = YuwellCt5TemperatureState();
      first.advance(0x42040000);
      second.advance(0x41e80000);

      expect(first.advance(0x41e80000), 0x42000000);
      expect(second.advance(0x42040000), 0x41f00000);
    });

    test('rejects words outside uint32 without mutation', () {
      _expectRejectedWithoutMutation(-1);
      _expectRejectedWithoutMutation(0x100000000);
    });

    test('rejects invalid first input without creating state', () {
      final state = YuwellCt5TemperatureState();

      expect(() => state.advance(0x7f800000), throwsArgumentError);
      expect(state.advance(0x41e80000), 0x41e80000);
    });

    test('rejects infinities without mutation', () {
      _expectRejectedWithoutMutation(0x7f800000);
      _expectRejectedWithoutMutation(0xff800000);
    });

    test('rejects NaN encodings without mutation', () {
      _expectRejectedWithoutMutation(0x7fc00000);
      _expectRejectedWithoutMutation(0x7f800001);
      _expectRejectedWithoutMutation(0xffc00000);
    });

    test('reset discards state and exposes positive zero', () {
      final state = YuwellCt5TemperatureState();
      state.advance(0x42040000);

      expect(state.reset(), 0x00000000);
      expect(state.advance(0x41e80000), 0x41e80000);
    });
  });
}

void _expectRejectedWithoutMutation(int rejectedBits) {
  final state = YuwellCt5TemperatureState();
  expect(state.advance(0x42040000), 0x42040000);
  expect(() => state.advance(rejectedBits), throwsA(anything));
  expect(state.advance(0x41e80000), 0x42000000);
}
