package com.aidex.aidex_flutter;

/** Synthetic composition matrix; no Android APIs, receiver files or RF. */
public final class LibreGen1ReceiverBackendPolicyTest {
  public static void main(String[] args) {
    for (int flags = 0; flags < 16; flags++) {
      boolean optedIn = (flags & 1) != 0;
      boolean debuggable = (flags & 2) != 0;
      boolean readerRegistered = (flags & 4) != 0;
      boolean recorderRegistered = (flags & 8) != 0;
      boolean allowed = LibreGen1ReceiverBackendPolicy.allows(
          optedIn, debuggable, readerRegistered, recorderRegistered);
      if (allowed != (flags == 7)) {
        throw new AssertionError("Only the exact opt-in private backend may restore a receiver.");
      }
    }
    // Engine detach removes the reader. It revokes bridge admission, not its
    // durable lease; the coordinator's destruction never asserts BLE closure.
    if (LibreGen1ReceiverBackendPolicy.allows(true, true, false, false)) {
      throw new AssertionError("Detached backend retained admission.");
    }
    System.out.println("Libre receiver backend composition synthetic checks passed.");
  }
}
