package com.aidex.aidex_flutter;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

/** Standalone JVM checks for the durable Yuwell activation write journal. */
public final class YuwellWriteJournalTest {
  private YuwellWriteJournalTest() {}

  public static void main(String[] arguments) throws Exception {
    prepareIsExclusiveAcrossThreads();
    staleTokenCannotMutateNewGeneration();
    transitionRulesFailClosed();
    backendFailuresPreserveUnresolvedState();
    corruptRecordBlocksActivation();
    recoveredResolutionChecksNonce();
    recoveredResolutionRequiresExactSnapshot();
    recoveredReplacementIsAtomicAndScoped();
    recoveredReplacementRequiresExactSnapshot();
    recoveredReplacementRejectsInvalidSources();
    recoveredReplacementFailurePreservesOldRecord();
  }

  private static void prepareIsExclusiveAcrossThreads() throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final CountDownLatch ready = new CountDownLatch(2);
    final CountDownLatch start = new CountDownLatch(1);
    final AtomicReference<String> firstToken = new AtomicReference<>();
    final AtomicReference<String> secondToken = new AtomicReference<>();
    final AtomicReference<Throwable> firstFailure = new AtomicReference<>();
    final AtomicReference<Throwable> secondFailure = new AtomicReference<>();

    final Thread first =
        new Thread(
            () -> {
              ready.countDown();
              runPrepare(
                  journal,
                  start,
                  "configure",
                  firstToken,
                  firstFailure);
            });
    final Thread second =
        new Thread(
            () -> {
              ready.countDown();
              runPrepare(
                  journal,
                  start,
                  "initialize",
                  secondToken,
                  secondFailure);
            });

    first.start();
    second.start();
    ready.await();
    start.countDown();
    first.join();
    second.join();

    final int successCount =
        (firstToken.get() == null ? 0 : 1)
            + (secondToken.get() == null ? 0 : 1);
    final int conflictCount =
        (firstFailure.get() instanceof YuwellWriteJournal.ConflictException
                ? 1
                : 0)
            + (secondFailure.get()
                    instanceof YuwellWriteJournal.ConflictException
                ? 1
                : 0);
    check(successCount == 1, "exactly one concurrent prepare must succeed");
    check(conflictCount == 1, "the second concurrent prepare must conflict");
    check(journal.hasUnresolved("sensor-key"), "winner must remain durable");
  }

  private static void staleTokenCannotMutateNewGeneration() throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String oldToken = journal.prepare("sensor-key", "setDate");
    journal.markTransmitted(oldToken);
    journal.markCompleted(oldToken);

    final String currentToken = journal.prepare("sensor-key", "initialize");
    journal.markTransmitted(currentToken);
    check(!oldToken.equals(currentToken), "each generation must use a fresh nonce");
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.markCompleted(oldToken));
    final YuwellWriteJournal.Snapshot current =
        journal.readUnresolved("sensor-key");
    check(current != null, "stale completion must preserve the current intent");
    check(
        currentToken.equals(current.token),
        "stale completion must not change the current nonce");
    check(
        "transmitted".equals(current.state),
        "stale completion must not change the current state");
  }

  private static void transitionRulesFailClosed() throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);

    final String cancelToken = journal.prepare("cancel-key", "setDate");
    journal.cancelPrepared(cancelToken);
    check(!journal.hasUnresolved("cancel-key"), "prepared cancellation must clear");

    final String token = journal.prepare("sensor-key", "configure");
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.markCompleted(token));
    journal.markTransmitted(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.markTransmitted(token));
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.cancelPrepared(token));
    journal.markUnknown(token);
    journal.markUnknown(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.markCompleted(token));
    check(journal.hasUnresolved("sensor-key"), "unknown outcome must remain unresolved");
  }

  private static void backendFailuresPreserveUnresolvedState()
      throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);

    backend.failNextWrite = true;
    expectFailure(BackendFailureException.class, () -> journal.prepare("prepare-key", "setDate"));
    check(
        !journal.hasUnresolved("prepare-key"),
        "failed prepare commit must not report a token or partial record");

    final String token = journal.prepare("sensor-key", "initialize");
    backend.failNextWrite = true;
    expectFailure(
        BackendFailureException.class, () -> journal.markTransmitted(token));
    YuwellWriteJournal.Snapshot snapshot =
        journal.readUnresolved("sensor-key");
    check(snapshot != null, "failed transition must preserve the intent");
    check(
        "prepared".equals(snapshot.state),
        "failed transition must preserve the prior state");

    journal.markTransmitted(token);
    backend.failNextRemove = true;
    expectFailure(
        BackendFailureException.class, () -> journal.markCompleted(token));
    snapshot = journal.readUnresolved("sensor-key");
    check(snapshot != null, "failed completion must preserve the intent");
    check(
        "transmitted".equals(snapshot.state),
        "failed completion must preserve the transmitted state");
  }

  private static void corruptRecordBlocksActivation() throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    backend.putRaw("sensor-key", "invalid-record");

    check(journal.hasUnresolved("sensor-key"), "corrupt record must remain unresolved");
    expectFailure(
        YuwellWriteJournal.FormatException.class,
        () -> journal.readUnresolved("sensor-key"));
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.prepare("sensor-key", "initialize"));
    check(journal.hasUnresolved("sensor-key"), "corrupt record must not be deleted");
  }

  private static void recoveredResolutionChecksNonce() throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String token = journal.prepare("sensor-key", "setCommunicationId");
    journal.markUnknown(token);
    final YuwellWriteJournal.Snapshot expected =
        journal.readUnresolved("sensor-key");

    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.resolveRecovered(
                replaceNonce(token), expected.operation, expected.state));
    check(
        journal.hasUnresolved("sensor-key"),
        "wrong recovery nonce must preserve the journal");
    journal.resolveRecovered(token, expected.operation, expected.state);
    check(
        !journal.hasUnresolved("sensor-key"),
        "proven recovery with the exact token must clear the journal");
  }

  private static void recoveredResolutionRequiresExactSnapshot()
      throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String token = journal.prepare("sensor-key", "setDate");
    final YuwellWriteJournal.Snapshot prepared =
        journal.readUnresolved("sensor-key");

    journal.markTransmitted(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.resolveRecovered(
                token, prepared.operation, prepared.state));
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () -> journal.resolveRecovered(token, "configure", "transmitted"));
    check(
        "transmitted".equals(journal.readUnresolved("sensor-key").state),
        "stale prepared resolution must preserve transmitted state");

    journal.markUnknown(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.resolveRecovered(
                token, prepared.operation, prepared.state));
    check(
        "unknown".equals(journal.readUnresolved("sensor-key").state),
        "stale prepared resolution must preserve unknown state");
  }

  private static void recoveredReplacementIsAtomicAndScoped()
      throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String oldToken =
        journal.prepare("sensor-key", "setCommunicationId");
    journal.markUnknown(oldToken);
    final YuwellWriteJournal.Snapshot source =
        journal.readUnresolved("sensor-key");
    final int writeCount = backend.writeCount;

    final String replacement =
        journal.replaceRecoveredWithPrepared(
            oldToken,
            "sensor-key",
            "setCommunicationId",
            source.operation,
            source.state);

    check(!replacement.equals(oldToken), "replacement must use a new nonce");
    check(
        backend.writeCount == writeCount + 1,
        "replacement must use one durable backend write");
    final YuwellWriteJournal.Snapshot snapshot =
        journal.readUnresolved("sensor-key");
    check(snapshot != null, "replacement must remain unresolved");
    check(replacement.equals(snapshot.token), "replacement token must be current");
    check(
        "setCommunicationId".equals(snapshot.operation),
        "replacement must preserve the set-ID operation");
    check("prepared".equals(snapshot.state), "replacement must be prepared");

    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                oldToken,
                "sensor-key",
                "setCommunicationId",
                source.operation,
                source.state));
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                replacement,
                "another-key",
                "setCommunicationId",
                snapshot.operation,
                snapshot.state));
    check(
        replacement.equals(journal.readUnresolved("sensor-key").token),
        "stale or cross-sensor replacement must preserve the current record");
  }

  private static void recoveredReplacementRequiresExactSnapshot()
      throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String token = journal.prepare("sensor-key", "setCommunicationId");
    final YuwellWriteJournal.Snapshot prepared =
        journal.readUnresolved("sensor-key");

    journal.markTransmitted(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                token,
                "sensor-key",
                "setCommunicationId",
                prepared.operation,
                prepared.state));
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                token,
                "sensor-key",
                "setCommunicationId",
                "configure",
                "transmitted"));
    check(
        "transmitted".equals(journal.readUnresolved("sensor-key").state),
        "stale prepared replacement must preserve transmitted state");

    journal.markUnknown(token);
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                token,
                "sensor-key",
                "setCommunicationId",
                prepared.operation,
                prepared.state));
    check(
        "unknown".equals(journal.readUnresolved("sensor-key").state),
        "stale prepared replacement must preserve unknown state");
  }

  private static void recoveredReplacementRejectsInvalidSources()
      throws Exception {
    final FakeBackend wrongSourceBackend = new FakeBackend();
    final YuwellWriteJournal wrongSourceJournal =
        new YuwellWriteJournal(wrongSourceBackend);
    final String initializeToken =
        wrongSourceJournal.prepare("sensor-key", "initialize");
    final YuwellWriteJournal.Snapshot initializeSource =
        wrongSourceJournal.readUnresolved("sensor-key");
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            wrongSourceJournal.replaceRecoveredWithPrepared(
                initializeToken,
                "sensor-key",
                "setCommunicationId",
                initializeSource.operation,
                initializeSource.state));
    check(
        initializeToken.equals(
            wrongSourceJournal.readUnresolved("sensor-key").token),
        "cross-operation source must remain unchanged");

    final FakeBackend wrongTargetBackend = new FakeBackend();
    final YuwellWriteJournal wrongTargetJournal =
        new YuwellWriteJournal(wrongTargetBackend);
    final String setIdToken =
        wrongTargetJournal.prepare("sensor-key", "setCommunicationId");
    final YuwellWriteJournal.Snapshot setIdSource =
        wrongTargetJournal.readUnresolved("sensor-key");
    expectFailure(
        YuwellWriteJournal.ConflictException.class,
        () ->
            wrongTargetJournal.replaceRecoveredWithPrepared(
                setIdToken,
                "sensor-key",
                "configure",
                setIdSource.operation,
                setIdSource.state));
    check(
        setIdToken.equals(wrongTargetJournal.readUnresolved("sensor-key").token),
        "cross-operation target must remain unchanged");

    final FakeBackend corruptBackend = new FakeBackend();
    final YuwellWriteJournal corruptJournal =
        new YuwellWriteJournal(corruptBackend);
    final String corruptToken =
        corruptJournal.prepare("sensor-key", "setCommunicationId");
    final YuwellWriteJournal.Snapshot corruptSource =
        corruptJournal.readUnresolved("sensor-key");
    corruptBackend.putRaw(
        "sensor-key",
        "1\nsetCommunicationId\ninvalid\n"
            + corruptToken.substring(corruptToken.length() - 64));
    expectFailure(
        YuwellWriteJournal.FormatException.class,
        () ->
            corruptJournal.replaceRecoveredWithPrepared(
                corruptToken,
                "sensor-key",
                "setCommunicationId",
                corruptSource.operation,
                corruptSource.state));
    check(
        corruptJournal.hasUnresolved("sensor-key"),
        "malformed source state must remain unresolved");
  }

  private static void recoveredReplacementFailurePreservesOldRecord()
      throws Exception {
    final FakeBackend backend = new FakeBackend();
    final YuwellWriteJournal journal = new YuwellWriteJournal(backend);
    final String token =
        journal.prepare("sensor-key", "setCommunicationId");
    journal.markUnknown(token);
    final YuwellWriteJournal.Snapshot source =
        journal.readUnresolved("sensor-key");
    final int writeCount = backend.writeCount;
    backend.failNextWrite = true;

    expectFailure(
        BackendFailureException.class,
        () ->
            journal.replaceRecoveredWithPrepared(
                token,
                "sensor-key",
                "setCommunicationId",
                source.operation,
                source.state));

    final YuwellWriteJournal.Snapshot snapshot =
        journal.readUnresolved("sensor-key");
    check(snapshot != null, "failed replacement must preserve the source");
    check(token.equals(snapshot.token), "failed replacement must preserve nonce");
    check("unknown".equals(snapshot.state), "failed replacement must preserve state");
    check(
        backend.writeCount == writeCount,
        "failed backend commit must not count as durable replacement");
  }

  private static void runPrepare(
      YuwellWriteJournal journal,
      CountDownLatch start,
      String operation,
      AtomicReference<String> token,
      AtomicReference<Throwable> failure) {
    try {
      start.await();
      token.set(journal.prepare("sensor-key", operation));
    } catch (Throwable error) {
      failure.set(error);
    }
  }

  private static String replaceNonce(String token) {
    return token.substring(0, token.length() - 64) + repeat('f', 64);
  }

  private static String repeat(char value, int count) {
    final char[] output = new char[count];
    for (int index = 0; index < count; index++) {
      output[index] = value;
    }
    return new String(output);
  }

  private static void expectFailure(
      Class<? extends Throwable> expected, ThrowingAction action)
      throws Exception {
    try {
      action.run();
      throw new AssertionError("expected fail-closed rejection");
    } catch (Throwable error) {
      if (!expected.isInstance(error)) {
        if (error instanceof Exception) {
          throw (Exception) error;
        }
        throw error;
      }
    }
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }

  private interface ThrowingAction {
    void run() throws Exception;
  }

  private static final class BackendFailureException extends Exception {}

  private static final class FakeBackend implements YuwellWriteJournal.Backend {
    private final Map<String, String> aliases = new HashMap<>();
    private final Map<String, String> records = new HashMap<>();
    private int nextAlias;
    private int nextNonce;
    int writeCount;
    boolean failNextWrite;
    boolean failNextRemove;

    @Override
    public String aliasFor(String storageKey) {
      String alias = aliases.get(storageKey);
      if (alias == null) {
        alias = hexCounter(++nextAlias);
        aliases.put(storageKey, alias);
      }
      return alias;
    }

    @Override
    public boolean contains(String alias) {
      return records.containsKey(alias);
    }

    @Override
    public String read(String alias) {
      return records.get(alias);
    }

    @Override
    public void write(String alias, String record) throws Exception {
      if (failNextWrite) {
        failNextWrite = false;
        throw new BackendFailureException();
      }
      records.put(alias, record);
      writeCount += 1;
    }

    @Override
    public void remove(String alias) throws Exception {
      if (failNextRemove) {
        failNextRemove = false;
        throw new BackendFailureException();
      }
      records.remove(alias);
    }

    @Override
    public String newNonce() {
      return hexCounter(++nextNonce);
    }

    void putRaw(String storageKey, String record) {
      records.put(aliasFor(storageKey), record);
    }

    private static String hexCounter(int value) {
      final String suffix = Integer.toHexString(value);
      return repeat('0', 64 - suffix.length()) + suffix;
    }
  }
}
