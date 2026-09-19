package com.aidex.aidex_flutter;

import java.util.Arrays;

/**
 * Pure Libre security-Gen1 activation and FRAM-integrity primitives.
 *
 * <p>This class performs no I/O. The debug NFC executor is responsible for
 * one-shot authorization, durable intent journaling, and point-of-use capture
 * health. The implementation is kept in parity with the audited Dart offline
 * core and is covered by shared golden vectors.
 */
final class LibreGen1Activation {
  static final int LIFECYCLE_NOT_ACTIVATED = 0x01;
  static final int LIFECYCLE_WARMING_UP = 0x02;
  static final int LIFECYCLE_ACTIVE = 0x03;
  static final int LIFECYCLE_EXPIRED = 0x04;
  static final int LIFECYCLE_SHUTDOWN = 0x05;
  static final int LIFECYCLE_FAILURE = 0x06;
  static final int ACTIVATION_REQUEST_BYTES = 8;
  static final int ACTIVATION_RESPONSE_BYTES = 5;

  private static final int[] KEY = {0xa0c5, 0x6860, 0x0000, 0x14c6};
  private static final int GEN1_SECRET = 0x1b6a;

  private LibreGen1Activation() {}

  /** Builds exactly {@code 02 A1 uid[6] 1B auth[4]}. */
  static byte[] activationRequest(byte[] algorithmOrderUid) {
    requireLength(algorithmOrderUid, 8, "UID");
    final byte[] authentication =
        usefulFunction(algorithmOrderUid, 0x1b, GEN1_SECRET);
    return new byte[] {
      (byte) 0x02,
      (byte) 0xa1,
      algorithmOrderUid[6],
      (byte) 0x1b,
      authentication[0],
      authentication[1],
      authentication[2],
      authentication[3],
    };
  }

  /**
   * Requires the exact reference response shape. This is not activation proof;
   * only a later CRC-valid FRAM lifecycle transition is proof.
   */
  static void requireActivationResponseShape(byte[] response) {
    if (response == null
        || response.length != ACTIVATION_RESPONSE_BYTES
        || (response[0] & 0x01) != 0) {
      throw new IllegalArgumentException("Invalid activation response shape.");
    }
  }

  /** Decrypts 43 FRAM blocks, verifies all three CRCs, and returns state byte. */
  static int validatedLifecycle(
      byte[] algorithmOrderUid, byte[] patchInfo, byte[] encryptedFram) {
    requireLength(algorithmOrderUid, 8, "UID");
    requireLength(patchInfo, 6, "patch info");
    requireLength(encryptedFram, LibreGen1NfcFrames.FRAM_BYTES, "FRAM");
    requireSupportedLibre2Gen1(patchInfo);

    final byte[] clear = new byte[LibreGen1NfcFrames.FRAM_BYTES];
    try {
      final int argument = (littleEndian16(patchInfo, 4) ^ 0x44) & 0xffff;
      for (int block = 0; block < 43; block += 1) {
        final int[] words =
            processCrypto(prepareVariables(algorithmOrderUid, block, argument));
        final byte[] keyBytes = wordsToLittleEndian(words);
        try {
          final int offset = block * 8;
          for (int index = 0; index < 8; index += 1) {
            clear[offset + index] =
                (byte) ((encryptedFram[offset + index] ^ keyBytes[index]) & 0xff);
          }
        } finally {
          Arrays.fill(keyBytes, (byte) 0);
          Arrays.fill(words, 0);
        }
      }
      requireRegionCrc(clear, 0, 24);
      requireRegionCrc(clear, 24, 320);
      requireRegionCrc(clear, 320, 344);
      return clear[4] & 0xff;
    } finally {
      // Decrypted FRAM includes health history. Only the closed lifecycle byte
      // may escape this method, on both success and every validation failure.
      Arrays.fill(clear, (byte) 0);
    }
  }

  /** Maps a CRC-validated lifecycle byte to the closed UI vocabulary. */
  static String closedLifecycleName(int lifecycle) {
    switch (lifecycle) {
      case LIFECYCLE_NOT_ACTIVATED:
        return "notActivated";
      case LIFECYCLE_WARMING_UP:
        return "warmingUp";
      case LIFECYCLE_ACTIVE:
        return "active";
      case LIFECYCLE_EXPIRED:
        return "expired";
      case LIFECYCLE_SHUTDOWN:
        return "shutdown";
      case LIFECYCLE_FAILURE:
        return "failure";
      default:
        return "unknown";
    }
  }

  private static void requireSupportedLibre2Gen1(byte[] patchInfo) {
    final int signature =
        ((patchInfo[0] & 0xff) << 16)
            | ((patchInfo[1] & 0xff) << 8)
            | (patchInfo[2] & 0xff);
    // The actual-send evidence covers Libre 2 only. Libre 2 Plus remains
    // blocked until a separately pinned state-changing call site exists.
    if (signature != 0x9d0830
        && signature != 0xc50930
        && signature != 0x7f0e30) {
      throw new IllegalArgumentException("Unsupported activation patch info.");
    }
  }

  private static int[] prepareVariables(byte[] uid, int x, int y) {
    return new int[] {
      (littleEndian16(uid, 4) + x + y) & 0xffff,
      (littleEndian16(uid, 2) + KEY[2]) & 0xffff,
      (littleEndian16(uid, 0) + (x * 2)) & 0xffff,
      0x241a ^ KEY[3],
    };
  }

  private static int[] processCrypto(int[] input) {
    final int r0 = operation(input[0]) ^ input[3];
    final int r1 = operation(r0) ^ input[2];
    final int r2 = operation(r1) ^ input[1];
    final int r3 = operation(r2) ^ input[0];
    final int r4 = operation(r3);
    final int r5 = operation(r4 ^ r0);
    final int r6 = operation(r5 ^ r1);
    final int r7 = operation(r6 ^ r2);
    return new int[] {
      (r3 ^ r7) & 0xffff,
      (r2 ^ r6) & 0xffff,
      (r1 ^ r5) & 0xffff,
      (r0 ^ r4) & 0xffff,
    };
  }

  private static int operation(int value) {
    int result = value >>> 2;
    if ((value & 1) != 0) {
      result ^= KEY[1];
    }
    if ((value & 2) != 0) {
      result ^= KEY[0];
    }
    return result & 0xffff;
  }

  private static byte[] usefulFunction(byte[] uid, int x, int y) {
    final int[] words = processCrypto(prepareVariables(uid, x, y));
    return wordsToLittleEndian(
        new int[] {words[0] ^ 0x4163, words[1] ^ 0x4344});
  }

  private static byte[] wordsToLittleEndian(int[] words) {
    final byte[] result = new byte[words.length * 2];
    for (int index = 0; index < words.length; index += 1) {
      result[index * 2] = (byte) (words[index] & 0xff);
      result[index * 2 + 1] = (byte) ((words[index] >>> 8) & 0xff);
    }
    return result;
  }

  private static int littleEndian16(byte[] bytes, int offset) {
    return (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);
  }

  private static void requireRegionCrc(byte[] bytes, int start, int end) {
    final int expected = littleEndian16(bytes, start);
    final int actual = crc16(bytes, start + 2, end);
    if (actual != expected) {
      throw new IllegalArgumentException("FRAM integrity check failed.");
    }
  }

  private static int crc16(byte[] bytes, int start, int end) {
    int crc = 0xffff;
    for (int index = start; index < end; index += 1) {
      crc ^= bytes[index] & 0xff;
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

  private static void requireLength(byte[] value, int expected, String label) {
    if (value == null || value.length != expected) {
      throw new IllegalArgumentException(label + " has an invalid length.");
    }
  }
}
