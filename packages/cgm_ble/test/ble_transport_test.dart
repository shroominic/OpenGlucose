import 'package:cgm_ble/cgm_ble.dart';
import 'package:test/test.dart';

void main() {
  test('characteristic refs preserve service and characteristic uuids', () {
    const ref = BleCharacteristicRef(
      serviceUuid: '181F',
      characteristicUuid: '2AA9',
    );
    expect(ref.serviceUuid, '181F');
    expect(ref.characteristicUuid, '2AA9');
  });
}
