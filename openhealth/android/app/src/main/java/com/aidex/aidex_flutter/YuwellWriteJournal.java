package com.aidex.aidex_flutter;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure state machine for the nonce-bound Yuwell durable write journal. */
final class YuwellWriteJournal {
  private static final String TOKEN_PREFIX = "ct5.intent.v2.";
  private static final Pattern HEX_256 = Pattern.compile("^[0-9a-f]{64}$");
  private static final Pattern TOKEN_PATTERN =
      Pattern.compile(
          "^ct5\\.intent\\.v2\\.([0-9a-f]{64})\\.([0-9a-f]{64})$");
  private static final Set<String> OPERATIONS =
      Collections.unmodifiableSet(
          new HashSet<>(
              Arrays.asList(
                  "setDate",
                  "setCommunicationId",
                  "configure",
                  "initialize",
                  "lowPower")));
  private static final Set<String> STATES =
      Collections.unmodifiableSet(
          new HashSet<>(Arrays.asList("prepared", "transmitted", "unknown")));

  interface Backend {
    String aliasFor(String storageKey) throws Exception;

    boolean contains(String alias) throws Exception;

    String read(String alias) throws Exception;

    void write(String alias, String record) throws Exception;

    void remove(String alias) throws Exception;

    String newNonce();
  }

  static final class Snapshot {
    final String token;
    final String operation;
    final String state;

    Snapshot(String token, String operation, String state) {
      this.token = token;
      this.operation = operation;
      this.state = state;
    }
  }

  static final class ConflictException extends Exception {}

  static final class FormatException extends Exception {}

  private final Backend backend;

  YuwellWriteJournal(Backend backend) {
    this.backend = backend;
  }

  synchronized boolean hasUnresolved(String storageKey) throws Exception {
    return backend.contains(requireAlias(backend.aliasFor(storageKey)));
  }

  synchronized Snapshot readUnresolved(String storageKey) throws Exception {
    final String alias = requireAlias(backend.aliasFor(storageKey));
    final Entry entry = readEntry(alias);
    if (entry == null) {
      return null;
    }
    return new Snapshot(
        TOKEN_PREFIX + alias + "." + entry.nonce,
        entry.operation,
        entry.state);
  }

  synchronized String prepare(String storageKey, String operation)
      throws Exception {
    if (!OPERATIONS.contains(operation)) {
      throw new FormatException();
    }
    final String alias = requireAlias(backend.aliasFor(storageKey));
    if (backend.contains(alias)) {
      throw new ConflictException();
    }
    final String nonce = requireNonce(backend.newNonce());
    backend.write(alias, encode(new Entry(operation, "prepared", nonce)));
    return TOKEN_PREFIX + alias + "." + nonce;
  }

  synchronized void markTransmitted(String token) throws Exception {
    transition(token, Collections.singleton("prepared"), "transmitted");
  }

  synchronized void markUnknown(String token) throws Exception {
    transition(
        token,
        new HashSet<>(Arrays.asList("prepared", "transmitted", "unknown")),
        "unknown");
  }

  synchronized void markCompleted(String token) throws Exception {
    remove(token, Collections.singleton("transmitted"));
  }

  synchronized void cancelPrepared(String token) throws Exception {
    remove(token, Collections.singleton("prepared"));
  }

  synchronized void resolveRecovered(
      String token, String expectedOperation, String expectedState)
      throws Exception {
    removeExpected(token, expectedOperation, expectedState);
  }

  /**
   * Atomically replaces a proven failed set-ID attempt with a new prepared
   * generation for the same sensor and operation.
   *
   * <p>The caller must first complete its read-only rejected check-ID proof.
   * This state machine then prevents a remove-plus-prepare gap, cross-sensor
   * replacement, cross-operation replacement, and stale-token or stale-snapshot
   * replacement.
   */
  synchronized String replaceRecoveredWithPrepared(
      String token,
      String storageKey,
      String operation,
      String expectedOperation,
      String expectedState)
      throws Exception {
    if (!"setCommunicationId".equals(operation)) {
      throw new ConflictException();
    }
    requireExpectedSnapshotValues(expectedOperation, expectedState);
    final TokenParts parts = parseToken(token);
    final String expectedAlias =
        requireAlias(backend.aliasFor(storageKey));
    if (!constantTimeEquals(parts.alias, expectedAlias)) {
      throw new ConflictException();
    }
    final Entry current = requireMatchingEntry(parts);
    if (!expectedOperation.equals(current.operation)
        || !expectedState.equals(current.state)
        || !"setCommunicationId".equals(current.operation)) {
      throw new ConflictException();
    }
    final String nonce = requireNonce(backend.newNonce());
    backend.write(
        parts.alias,
        encode(new Entry("setCommunicationId", "prepared", nonce)));
    return TOKEN_PREFIX + parts.alias + "." + nonce;
  }

  private void transition(
      String token, Set<String> allowedStates, String nextState)
      throws Exception {
    final TokenParts parts = parseToken(token);
    final Entry current = requireMatchingEntry(parts);
    if (!allowedStates.contains(current.state)) {
      throw new ConflictException();
    }
    backend.write(
        parts.alias,
        encode(new Entry(current.operation, nextState, current.nonce)));
  }

  private void remove(String token, Set<String> allowedStates) throws Exception {
    final TokenParts parts = parseToken(token);
    final Entry current = requireMatchingEntry(parts);
    if (!allowedStates.contains(current.state)) {
      throw new ConflictException();
    }
    backend.remove(parts.alias);
  }

  private void removeExpected(
      String token, String expectedOperation, String expectedState)
      throws Exception {
    requireExpectedSnapshotValues(expectedOperation, expectedState);
    final TokenParts parts = parseToken(token);
    final Entry current = requireMatchingEntry(parts);
    if (!expectedOperation.equals(current.operation)
        || !expectedState.equals(current.state)) {
      throw new ConflictException();
    }
    backend.remove(parts.alias);
  }

  private static void requireExpectedSnapshotValues(
      String expectedOperation, String expectedState) throws FormatException {
    if (!OPERATIONS.contains(expectedOperation)
        || !STATES.contains(expectedState)) {
      throw new FormatException();
    }
  }

  private Entry requireMatchingEntry(TokenParts parts) throws Exception {
    final Entry current = readEntry(parts.alias);
    if (current == null
        || !constantTimeEquals(current.nonce, parts.nonce)) {
      throw new ConflictException();
    }
    return current;
  }

  private static boolean constantTimeEquals(String first, String second) {
    return MessageDigest.isEqual(
        first.getBytes(StandardCharsets.US_ASCII),
        second.getBytes(StandardCharsets.US_ASCII));
  }

  private Entry readEntry(String alias) throws Exception {
    final String encoded = backend.read(alias);
    return encoded == null ? null : decode(encoded);
  }

  private static String encode(Entry entry) {
    return "1\n" + entry.operation + "\n" + entry.state + "\n" + entry.nonce;
  }

  private static Entry decode(String encoded) throws FormatException {
    final String[] fields = encoded.split("\\n", -1);
    if (fields.length != 4
        || !"1".equals(fields[0])
        || !OPERATIONS.contains(fields[1])
        || !STATES.contains(fields[2])
        || !HEX_256.matcher(fields[3]).matches()) {
      throw new FormatException();
    }
    return new Entry(fields[1], fields[2], fields[3]);
  }

  private static TokenParts parseToken(String token) throws FormatException {
    final Matcher matcher = TOKEN_PATTERN.matcher(token);
    if (!matcher.matches()) {
      throw new FormatException();
    }
    return new TokenParts(matcher.group(1), matcher.group(2));
  }

  private static String requireAlias(String alias) throws FormatException {
    if (!HEX_256.matcher(alias).matches()) {
      throw new FormatException();
    }
    return alias;
  }

  private static String requireNonce(String nonce) throws FormatException {
    if (!HEX_256.matcher(nonce).matches()) {
      throw new FormatException();
    }
    return nonce;
  }

  private static final class Entry {
    final String operation;
    final String state;
    final String nonce;

    Entry(String operation, String state, String nonce) {
      this.operation = operation;
      this.state = state;
      this.nonce = nonce;
    }
  }

  private static final class TokenParts {
    final String alias;
    final String nonce;

    TokenParts(String alias, String nonce) {
      this.alias = alias;
      this.nonce = nonce;
    }
  }
}
