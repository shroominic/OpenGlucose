package com.aidex.aidex_flutter;

/** Standalone JVM checks for the failed-commit poison latch. */
public final class YuwellStoreHealthTest {
  private YuwellStoreHealthTest() {}

  public static void main(String[] arguments) {
    final YuwellStoreHealth health = new YuwellStoreHealth();
    check(!health.isPoisoned(), "new process storage must start healthy");
    health.poison();
    check(health.isPoisoned(), "failed commit must poison the process");
    health.poison();
    check(health.isPoisoned(), "poison must be irreversible until restart");
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
