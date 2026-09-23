package com.aidex.aidex_flutter;

import java.util.Arrays;

/** Standalone JVM parity checks for the debug-only activation gate. */
public final class LibreGen1ActivationTest {
  private static final String SYNTHETIC_ENCRYPTED =
      "fbd6e447b519369a3bfe1348b837c3820b31c742fe1c595f"
          + "f557302d47328c477e07b30886ce3e4548a3c4873fe0cb5d"
          + "38ec900db9cb51c08ea8e7a200e5c45883377e52eb8c8bac"
          + "355309dd5222fe34851c5d571489e46933582a382d27b1f1d"
          + "a81737b94e269176c258474ad4c1c8f1cea507eabe706122a"
          + "2ea7519249930ab82fca59886099de8ecb3d56b14e6cc6be"
          + "04e95cf765f61b88c01e334e4b2303cb329d168fb79101fd"
          + "96ea99369964198dd9be13b0b2fe843b9dc9bc099c6b1c36"
          + "02504ce2f524e8806627c35b5b5170302973491df04b2d866"
          + "d0426245e1eb53b67deab0083aa318dc329a4392ddfa9fd0c"
          + "fdae3f86c534cbc80a810628502cdbcf7f933c695bf8ed2b8"
          + "89c0547aee0dde45c96436c343deb20abf9fa42e125a8d228"
          + "dc3bbe53279e765f538290a63fee390bd904bb3ca2587d7c7"
          + "6bd95a93a359ee58656fce6cee3869209ef52935653c9c683"
          + "a9f9890b";
  // Pinned LibreTools Example2, revision
  // d54b0883959420e5941ed293ec6b9ef2474b7ed3.
  private static final String REAL_EXAMPLE2_ENCRYPTED =
      "520bf344dca04321cc7dd74e29e282e3e704c9cf6c572c7d"
          + "a88210aad73219b3c79f395fe37a4508b709bc6efada3407b"
          + "46568607ea504e665654813f89ca7c870a74d9d523586f202"
          + "cc9b9b7432ffc5bfe9781f46c2c70b0fb0c85423e20d4497"
          + "44368fac12ae4a6ce137e2462b5c741b7afe674fccdd95177"
          + "3b325e9aba65e70e46cce568db9e5feaa503652d2c522243"
          + "9d863086204adfa89001072cfa9f3474bf57096f28acaffef"
          + "a39e1aec9f4a2fe8a9cae6c8744698b2a29e8df0af09c15b"
          + "52597e00d33f59417b33eedb4051b23d9482f3b2e4caad3c"
          + "d8c0d7d74c51caa3ad2624ab10ba6135e17f3d3fecb4cfe3"
          + "a2316ae7d73618215b435a9c757c89e2496cb1716a476e8ae"
          + "5b2c537e9e5ddb31237957ad01f73ebb815f1e65d51fb1688"
          + "a69c17b0400ebbd7ca9dcd8b60888854fc657143e751e218e"
          + "a631d5baad1d3d708b7ed87c4b42431e7a0e6595193fda3e"
          + "6bfe1f209";

  public static void main(String[] arguments) {
    verifiesDartActivationVector();
    verifiesCrcBoundLifecycleTransitions();
    verifiesPinnedRealUidOrder();
    rejectsInvalidInputsAndResponseShapes();
  }

  private static void verifiesPinnedRealUidOrder() {
    final byte[] directUid = hex("df20be0000a407e0");
    final byte[] patch = hex("9d0830017625");
    final byte[] encrypted = hex(REAL_EXAMPLE2_ENCRYPTED);
    check(
        LibreGen1Activation.validatedLifecycle(directUid, patch, encrypted)
            == 0x03,
        "pinned real vector must validate in direct Android UID order");
    final byte[] reversed = directUid.clone();
    for (int left = 0, right = reversed.length - 1;
        left < right;
        left += 1, right -= 1) {
      final byte value = reversed[left];
      reversed[left] = reversed[right];
      reversed[right] = value;
    }
    expectFailure(
        () -> LibreGen1Activation.validatedLifecycle(reversed, patch, encrypted));
  }

  private static void verifiesDartActivationVector() {
    check(
        Arrays.equals(
            LibreGen1Activation.activationRequest(hex("0011223344556677")),
            hex("02a1661beb0956b9")),
        "native activation request must match the Dart golden vector");
    check(
        Arrays.equals(
            LibreGen1Activation.activationRequest(hex("01020304050607e0")),
            hex("02a1071bb02481cc")),
        "native activation request must match the host grant vector");
  }

  private static void verifiesCrcBoundLifecycleTransitions() {
    final byte[] uid = hex("0011223344556677");
    final byte[] patch = hex("9d0830013412");
    final byte[] referenceEncrypted = hex(SYNTHETIC_ENCRYPTED);
    final byte[] activeClear = syntheticClearFram(0x03);
    final String[] expectedNames = {
      "notActivated", "warmingUp", "active", "expired", "shutdown", "failure"
    };
    for (int lifecycle = 0x01; lifecycle <= 0x06; lifecycle += 1) {
      final byte[] desiredClear = syntheticClearFram(lifecycle);
      final byte[] encrypted = new byte[referenceEncrypted.length];
      for (int index = 0; index < encrypted.length; index += 1) {
        encrypted[index] =
            (byte) (referenceEncrypted[index] ^ activeClear[index] ^ desiredClear[index]);
      }
      check(
          LibreGen1Activation.validatedLifecycle(uid, patch, encrypted) == lifecycle,
          "CRC-valid lifecycle did not match the Dart fixture");
      check(
          LibreGen1Activation.closedLifecycleName(lifecycle)
              .equals(expectedNames[lifecycle - 1]),
          "closed lifecycle name did not match the UI contract");
    }

    for (int lifecycle : new int[] {0x00, 0x07, 0xff}) {
      check(
          LibreGen1Activation.closedLifecycleName(lifecycle).equals("unknown"),
          "every unrecognized CRC-valid lifecycle must stay closed");
    }
    for (int corruptedIndex : new int[] {10, 100, 330}) {
      final byte[] corrupted = referenceEncrypted.clone();
      corrupted[corruptedIndex] ^= 1;
      expectFailure(
          () -> LibreGen1Activation.validatedLifecycle(uid, patch, corrupted));
    }
  }

  private static void rejectsInvalidInputsAndResponseShapes() {
    expectFailure(() -> LibreGen1Activation.activationRequest(new byte[7]));
    expectFailure(
        () ->
            LibreGen1Activation.validatedLifecycle(
                new byte[8], hex("c60931010000"), new byte[344]));
    LibreGen1Activation.requireActivationResponseShape(new byte[5]);
    expectFailure(
        () -> LibreGen1Activation.requireActivationResponseShape(new byte[4]));
    final byte[] error = new byte[5];
    error[0] = 1;
    expectFailure(() -> LibreGen1Activation.requireActivationResponseShape(error));
  }

  private static byte[] syntheticClearFram(int lifecycle) {
    final byte[] bytes = new byte[344];
    for (int index = 0; index < bytes.length; index += 1) {
      bytes[index] = (byte) ((index * 73 + 19) & 0xff);
    }
    bytes[4] = (byte) lifecycle;
    writeRegionCrc(bytes, 0, 24);
    writeRegionCrc(bytes, 24, 320);
    writeRegionCrc(bytes, 320, 344);
    return bytes;
  }

  private static void writeRegionCrc(byte[] bytes, int start, int end) {
    final int crc = crc16(Arrays.copyOfRange(bytes, start + 2, end));
    bytes[start] = (byte) (crc & 0xff);
    bytes[start + 1] = (byte) ((crc >>> 8) & 0xff);
  }

  private static int crc16(byte[] bytes) {
    int crc = 0xffff;
    for (byte encoded : bytes) {
      crc ^= encoded & 0xff;
      for (int bit = 0; bit < 8; bit += 1) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0x8408 : crc >>> 1;
      }
    }
    int reversed = 0;
    for (int bit = 0; bit < 16; bit += 1) {
      reversed = (reversed << 1) | (crc & 1);
      crc >>>= 1;
    }
    return reversed & 0xffff;
  }

  private static byte[] hex(String value) {
    final byte[] result = new byte[value.length() / 2];
    for (int index = 0; index < result.length; index += 1) {
      result[index] =
          (byte) Integer.parseInt(value.substring(index * 2, index * 2 + 2), 16);
    }
    return result;
  }

  private static void expectFailure(Runnable action) {
    try {
      action.run();
      throw new AssertionError("expected fail-closed rejection");
    } catch (IllegalArgumentException expected) {
      // Expected.
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
