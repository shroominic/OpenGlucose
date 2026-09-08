package com.aidex.aidex_flutter;

/** Process-wide fail-closed state after an uncertain durable-store commit. */
final class YuwellStoreHealth {
  private boolean poisoned;

  synchronized boolean isPoisoned() {
    return poisoned;
  }

  synchronized void poison() {
    poisoned = true;
  }
}
