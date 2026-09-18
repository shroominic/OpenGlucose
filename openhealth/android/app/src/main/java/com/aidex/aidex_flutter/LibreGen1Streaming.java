package com.aidex.aidex_flutter;

import java.util.Arrays;
import java.util.Locale;

/** Pure Gen1 streaming primitives. MIT provenance: cgm_libre2/THIRD_PARTY_NOTICES.md. */
final class LibreGen1Streaming {
  private LibreGen1Streaming() {}

  /** Android ISO15693 framing of the pinned DiaBLE A1/1E custom request. */
  static byte[] request(byte[] uid, byte[] initialPatchInfo, long streamingBase) {
    requireInputs(uid, initialPatchInfo, streamingBase);
    final int secret = le16(initialPatchInfo, 4) ^ (int) (streamingBase & 0xffff);
    final int[] input = {
      (le16(uid, 4) + 0x1e + secret) & 0xffff,
      le16(uid, 2),
      (le16(uid, 0) + 0x3c) & 0xffff,
      0x241a ^ 0x14c6,
    };
    final int r0 = operation(input[0]) ^ input[3];
    final int r1 = operation(r0) ^ input[2];
    final int r2 = operation(r1) ^ input[1];
    final int r3 = operation(r2) ^ input[0];
    final int r4 = operation(r3);
    final int r5 = operation(r4 ^ r0);
    final int r6 = operation(r5 ^ r1);
    final int r7 = operation(r6 ^ r2);
    final int first = r3 ^ r7 ^ 0x4163;
    final int second = r2 ^ r6 ^ 0x4344;
    Arrays.fill(input, 0);
    return new byte[] {
      0x02, (byte) 0xa1, uid[6], 0x1e,
      (byte) streamingBase, (byte) (streamingBase >>> 8),
      (byte) (streamingBase >>> 16), (byte) (streamingBase >>> 24),
      (byte) first, (byte) (first >>> 8), (byte) second, (byte) (second >>> 8),
    };
  }

  /** Six response bytes are reversed by the pinned reference to form a MAC. */
  static String deviceId(byte[] rawIso15693Response) {
    if (rawIso15693Response == null || rawIso15693Response.length != 7
        || rawIso15693Response[0] != 0) {
      throw new IllegalArgumentException("Invalid streaming response.");
    }
    boolean allZero = true;
    boolean allOnes = true;
    final StringBuilder result = new StringBuilder(17);
    for (int index = 6; index >= 1; index -= 1) {
      final int value = rawIso15693Response[index] & 0xff;
      allZero &= value == 0;
      allOnes &= value == 0xff;
      if (index < 6) result.append(':');
      result.append(String.format(Locale.ROOT, "%02X", value));
    }
    if (allZero || allOnes) throw new IllegalArgumentException("Invalid streaming address.");
    return result.toString();
  }

  static void requireInputs(byte[] uid, byte[] patch, long base) {
    if (uid == null || uid.length != 8 || patch == null || patch.length != 6
        || base < 0 || base > 0xffffffffL) {
      throw new IllegalArgumentException("Invalid streaming inputs.");
    }
    final int signature = ((patch[0] & 0xff) << 16)
        | ((patch[1] & 0xff) << 8) | (patch[2] & 0xff);
    if (signature != 0x9d0830 && signature != 0xc50930 && signature != 0x7f0e30) {
      throw new IllegalArgumentException("Unsupported streaming model.");
    }
  }

  static void requireLifecycle(int lifecycle) {
    if (lifecycle != LibreGen1Activation.LIFECYCLE_WARMING_UP
        && lifecycle != LibreGen1Activation.LIFECYCLE_ACTIVE) {
      throw new IllegalArgumentException("Lifecycle does not permit streaming.");
    }
  }

  /** Failed close or missing audit retains ownership; release must also prove success. */
  static boolean completeTransport(boolean closed, boolean audited,
      java.util.function.BooleanSupplier releaseExactLease) {
    return closed && audited && releaseExactLease.getAsBoolean();
  }

  private static int le16(byte[] bytes, int offset) {
    return (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);
  }

  private static int operation(int value) {
    int result = value >>> 2;
    if ((value & 1) != 0) result ^= 0x6860;
    if ((value & 2) != 0) result ^= 0xa0c5;
    return result & 0xffff;
  }

  /** Consumes one patch read, fifteen fixed FRAM reads, and one enable frame. */
  static final class Sequence {
    private final byte[] enable;
    private int next;
    private boolean lifecycleVerified;

    Sequence(byte[] enable) { this.enable = enable.clone(); }

    synchronized void verifyLifecycle(int lifecycle) {
      if (next != 16 || lifecycleVerified) throw new IllegalStateException("Wrong streaming stage.");
      requireLifecycle(lifecycle);
      lifecycleVerified = true;
    }

    synchronized boolean consume(byte[] request) {
      final byte[] expected;
      if (next == 0) {
        expected = new byte[] {0x02, (byte) 0xa1, 0x07};
      } else if (next < 16) {
        expected = LibreGen1NfcFrames.frames().get(next - 1).request();
      } else if (next == 16 && lifecycleVerified) {
        expected = enable;
      } else {
        return false;
      }
      if (!Arrays.equals(expected, request)) return false;
      next += 1; // Consume BEFORE transport I/O; an exception never rewinds it.
      return true;
    }
  }
}
