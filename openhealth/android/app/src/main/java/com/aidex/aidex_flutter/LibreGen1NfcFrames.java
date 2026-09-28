package com.aidex.aidex_flutter;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Fixed, read-only ISO 15693 frames for a target-unverified Libre Gen1 FRAM
 * capture.
 *
 * <p>This helper deliberately has no transport, retry, fallback, or write
 * behavior. Callers must enforce authorization and capture health at each
 * point of use.
 */
final class LibreGen1NfcFrames {
  static final int FIRST_BLOCK = 0;
  static final int LAST_BLOCK = 42;
  static final int BLOCK_BYTES = 8;
  static final int MAX_BLOCKS_PER_REQUEST = 3;
  static final int REQUEST_COUNT = 15;
  static final int FRAM_BYTES = 344;
  static final int MAX_RESPONSE_BYTES = 1 + (MAX_BLOCKS_PER_REQUEST * BLOCK_BYTES);

  private static final byte ISO15693_HIGH_DATA_RATE_FLAGS = (byte) 0x02;
  private static final byte ISO15693_READ_MULTIPLE_BLOCKS = (byte) 0x23;
  private static final List<Frame> FRAMES = buildFrames();

  private LibreGen1NfcFrames() {}

  static List<Frame> frames() {
    return FRAMES;
  }

  static byte[] concatenatePayloads(List<byte[]> payloads) {
    if (payloads == null || payloads.size() != FRAMES.size()) {
      throw new IllegalArgumentException("Expected the complete fixed FRAM sequence.");
    }
    final byte[] fram = new byte[FRAM_BYTES];
    int offset = 0;
    for (int index = 0; index < FRAMES.size(); index += 1) {
      final byte[] payload = payloads.get(index);
      final int expectedLength = FRAMES.get(index).blockCount * BLOCK_BYTES;
      if (payload == null || payload.length != expectedLength) {
        throw new IllegalArgumentException("FRAM payload length does not match its frame.");
      }
      System.arraycopy(payload, 0, fram, offset, payload.length);
      offset += payload.length;
    }
    if (offset != FRAM_BYTES) {
      throw new IllegalArgumentException("FRAM sequence did not cover exactly 344 bytes.");
    }
    return fram;
  }

  private static List<Frame> buildFrames() {
    final List<Frame> frames = new ArrayList<>(REQUEST_COUNT);
    int nextBlock = FIRST_BLOCK;
    while (nextBlock <= LAST_BLOCK) {
      final int remaining = LAST_BLOCK - nextBlock + 1;
      final int blockCount = Math.min(MAX_BLOCKS_PER_REQUEST, remaining);
      frames.add(new Frame(nextBlock, blockCount));
      nextBlock += blockCount;
    }
    if (frames.size() != REQUEST_COUNT || nextBlock != LAST_BLOCK + 1) {
      throw new IllegalStateException("Fixed Libre Gen1 FRAM frame coverage is invalid.");
    }
    return Collections.unmodifiableList(frames);
  }

  static final class Frame {
    private final int startBlock;
    private final int blockCount;

    private Frame(int startBlock, int blockCount) {
      if (startBlock < FIRST_BLOCK
          || startBlock > LAST_BLOCK
          || blockCount < 1
          || blockCount > MAX_BLOCKS_PER_REQUEST
          || startBlock + blockCount - 1 > LAST_BLOCK) {
        throw new IllegalArgumentException("Invalid fixed FRAM frame.");
      }
      this.startBlock = startBlock;
      this.blockCount = blockCount;
    }

    int startBlock() {
      return startBlock;
    }

    int blockCount() {
      return blockCount;
    }

    byte[] request() {
      return new byte[] {
        ISO15693_HIGH_DATA_RATE_FLAGS,
        ISO15693_READ_MULTIPLE_BLOCKS,
        (byte) startBlock,
        (byte) (blockCount - 1),
      };
    }

    byte[] payloadFromResponse(byte[] response) {
      final int expectedLength = 1 + (blockCount * BLOCK_BYTES);
      if (response == null
          || response.length != expectedLength
          || (response[0] & 0x01) != 0) {
        throw new IllegalArgumentException("Invalid ISO 15693 read response.");
      }
      final byte[] payload = new byte[expectedLength - 1];
      System.arraycopy(response, 1, payload, 0, payload.length);
      return payload;
    }
  }
}
