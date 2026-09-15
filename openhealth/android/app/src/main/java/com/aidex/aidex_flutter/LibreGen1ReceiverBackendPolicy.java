package com.aidex.aidex_flutter;

/** Exact private-validation admission; no capability here proves RF cleanup. */
final class LibreGen1ReceiverBackendPolicy {
  private LibreGen1ReceiverBackendPolicy() {}

  static boolean allows(boolean readOnlySelected, boolean debuggable,
      boolean readOnlyRegistered, boolean recorderRegistered) {
    return readOnlySelected && debuggable && readOnlyRegistered && !recorderRegistered;
  }
}
