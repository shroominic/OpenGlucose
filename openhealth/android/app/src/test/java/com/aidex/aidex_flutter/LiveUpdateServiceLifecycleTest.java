package com.aidex.aidex_flutter;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Synthetic process/queue interleavings only; no Android service or device. */
public final class LiveUpdateServiceLifecycleTest {
  public static void main(String[] args) {
    completionWaitsForForegroundAndOccursOnce();
    endBeforeStartRejectsLateIntent();
    timeoutRejectsLateIntentAndCompletion();
    delayedTimeoutHandlerCannotAdmitExpiredStart();
    persistenceCannotCarryAdmissionPastDeadline();
    deadlineCrossingDuringForegroundCannotReportSuccess();
    oldEpochCannotReplaceNewerService();
    restartTokenCannotReuseEpoch();
    failedStartDoesNotRetainOwnership();
    statusOnlyPayloadIsFixedAndIdentityFree();
    System.out.println("Live-update service lifecycle synthetic checks passed.");
  }

  private static void completionWaitsForForegroundAndOccursOnce() {
    LiveUpdateServiceLifecycle policy = policy();
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(true, results);
    check(results.values.isEmpty(), "request receipt reported foreground success");
    check(policy.admit(operation.incarnation, operation.epoch, true) == operation,
        "current status-only start rejected");
    check(policy.admit(operation.incarnation, operation.epoch, false) == null,
        "status-only owner accepted a numeric start action");
    check(policy.started(operation), "foreground completion rejected");
    check(results.values.size() == 1 && results.values.get(0) == null,
        "successful foreground start was not acknowledged once");
    check(!policy.timeout(operation), "completed service expired on startup timer");
    policy.started(operation);
    policy.invalidate();
    policy.invalidate();
    check(results.values.size() == 1, "callback completed more than once");
    check(policy.current() == null, "end retained service ownership");
  }

  private static void endBeforeStartRejectsLateIntent() {
    LiveUpdateServiceLifecycle policy = policy();
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(true, results);
    policy.invalidate();
    check(results.only(LiveUpdateServiceLifecycle.Failure.CANCELLED),
        "end did not cancel pending acknowledgement");
    check(policy.admit(operation.incarnation, operation.epoch, true) == null,
        "queued start revived ended service");
    check(!policy.started(operation), "late completion revived ended owner");
    check(!policy.timeout(operation), "old timer changed ended ownership");
    check(results.values.size() == 1, "late completion replied twice");
  }

  private static void timeoutRejectsLateIntentAndCompletion() {
    FakeClock clock = new FakeClock();
    LiveUpdateServiceLifecycle policy = new LiveUpdateServiceLifecycle("synthetic-process-one", clock);
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(true, results);
    check(!policy.timeout(operation), "early timer revoked a valid pending start");
    clock.elapsedMillis = LiveUpdateServiceLifecycle.START_TIMEOUT_MILLIS;
    check(policy.timeout(operation), "startup timeout did not revoke ownership");
    check(results.only(LiveUpdateServiceLifecycle.Failure.TIMED_OUT),
        "timeout reported success or wrong failure");
    check(policy.admit(operation.incarnation, operation.epoch, true) == null,
        "late service start admitted after timeout");
    check(!policy.started(operation) && !policy.timeout(operation),
        "late callback or timer reclaimed timed-out ownership");
    check(results.values.size() == 1, "timeout completed more than once");
  }

  private static void delayedTimeoutHandlerCannotAdmitExpiredStart() {
    FakeClock clock = new FakeClock();
    LiveUpdateServiceLifecycle policy = new LiveUpdateServiceLifecycle("synthetic-process-one", clock);
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(true, results);
    clock.elapsedMillis = LiveUpdateServiceLifecycle.START_TIMEOUT_MILLIS + 1;
    // No timeout callback ran: simulate onStartCommand ahead of its overdue Handler.
    check(policy.admit(operation.incarnation, operation.epoch, true) == null,
        "late admission depended on delayed Handler delivery");
    check(results.only(LiveUpdateServiceLifecycle.Failure.TIMED_OUT),
        "late admission did not finish as timeout");
    check(policy.current() == null && !policy.started(operation),
        "expired admission retained ownership or acknowledged success");
  }

  private static void persistenceCannotCarryAdmissionPastDeadline() {
    FakeClock clock = new FakeClock();
    LiveUpdateServiceLifecycle policy = new LiveUpdateServiceLifecycle("synthetic-process-one", clock);
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(false, results);
    check(policy.admit(operation.incarnation, operation.epoch, false) == operation,
        "fresh admission rejected");
    // Preference persistence and notification construction have finished only now.
    clock.elapsedMillis = LiveUpdateServiceLifecycle.START_TIMEOUT_MILLIS;
    int foregroundEffects = 0;
    if (policy.beforeForeground(operation)) foregroundEffects++;
    check(foregroundEffects == 0 && policy.current() == null,
        "slow persistence allowed a late foreground effect");
    check(results.only(LiveUpdateServiceLifecycle.Failure.TIMED_OUT),
        "expiry during persistence falsely reported success");
  }

  private static void deadlineCrossingDuringForegroundCannotReportSuccess() {
    FakeClock clock = new FakeClock();
    LiveUpdateServiceLifecycle policy = new LiveUpdateServiceLifecycle("synthetic-process-one", clock);
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(true, results);
    clock.elapsedMillis = LiveUpdateServiceLifecycle.START_TIMEOUT_MILLIS - 1;
    check(policy.beforeForeground(operation), "unexpired foreground effect rejected");
    clock.elapsedMillis++;
    check(!policy.started(operation) && policy.current() == null,
        "expired foreground completion retained owner instead of requiring stop");
    check(results.only(LiveUpdateServiceLifecycle.Failure.TIMED_OUT),
        "foreground completion crossed deadline but reported success");
  }

  private static void oldEpochCannotReplaceNewerService() {
    LiveUpdateServiceLifecycle policy = policy();
    Results firstResults = new Results(), secondResults = new Results();
    LiveUpdateServiceLifecycle.Operation first = policy.begin(false, firstResults);
    LiveUpdateServiceLifecycle.Operation second = policy.begin(true, secondResults);
    check(firstResults.only(LiveUpdateServiceLifecycle.Failure.CANCELLED),
        "superseded start did not finish as cancelled");
    check(second.epoch > first.epoch, "operation epoch did not advance");
    check(policy.admit(first.incarnation, first.epoch, false) == null,
        "queued numeric start overwrote newer redacted owner");
    check(!policy.timeout(first), "old timer revoked newer service");
    check(!policy.fail(first, LiveUpdateServiceLifecycle.Failure.START_FAILED),
        "old failure revoked newer service");
    check(policy.current() == second, "stale rejection removed newer owner");
    check(policy.started(second), "newer service failed to acknowledge");
    // Privacy refresh is another explicit owner, not authority from cached data.
    policy.invalidate();
    LiveUpdateServiceLifecycle.Operation refreshed = policy.begin(false, new Results());
    check(refreshed.epoch > second.epoch, "privacy refresh reused old epoch");
    check(policy.admit(second.incarnation, second.epoch, true) == null,
        "old status start survived privacy refresh");
  }

  private static void restartTokenCannotReuseEpoch() {
    LiveUpdateServiceLifecycle firstProcess = policy();
    LiveUpdateServiceLifecycle.Operation old = firstProcess.begin(true, new Results());
    LiveUpdateServiceLifecycle nextProcess =
        new LiveUpdateServiceLifecycle("synthetic-process-two", new FakeClock());
    check(nextProcess.current() == null, "new process inferred cached ownership");
    check(nextProcess.admit(old.incarnation, old.epoch, true) == null,
        "restart restored an old intent without an owner");
    LiveUpdateServiceLifecycle.Operation current = nextProcess.begin(true, new Results());
    check(current.epoch == old.epoch, "fixture does not exercise numeric epoch reuse");
    check(nextProcess.admit(old.incarnation, old.epoch, true) == null,
        "old process intent reused a new process epoch");
    check(nextProcess.admit(null, current.epoch, true) == null,
        "missing process token accepted");
    check(nextProcess.admit(current.incarnation, 0, true) == null,
        "missing operation epoch accepted");
  }

  private static void failedStartDoesNotRetainOwnership() {
    LiveUpdateServiceLifecycle policy = policy();
    Results results = new Results();
    LiveUpdateServiceLifecycle.Operation operation = policy.begin(false, results);
    check(policy.fail(operation, LiveUpdateServiceLifecycle.Failure.START_FAILED),
        "native failure was ignored");
    check(results.only(LiveUpdateServiceLifecycle.Failure.START_FAILED),
        "native failure falsely reported start success");
    check(policy.current() == null && !policy.started(operation),
        "failed service retained ownership");
    check(policy.admit(operation.incarnation, operation.epoch, false) == null,
        "failed start intent remained replayable");
  }

  private static void statusOnlyPayloadIsFixedAndIdentityFree() {
    Map<String, Object> payload = LiveUpdateServiceLifecycle.connectionStatusPayload();
    check(Boolean.TRUE.equals(payload.get("connectionStatusOnly")), "status-only marker missing");
    check("OpenGlucose".equals(payload.get("sensorName")), "sensor name replaced app brand");
    check("Sensor connection service is running".equals(payload.get("detailText")),
        "unexpected detail text");
    check("Sensor connection".equals(payload.get("stageLabel")),
        "status wording claims an established radio connection");
    for (String key : new String[] {"unitText", "lifeText", "trendSymbol", "deltaText"}) {
      check("".equals(payload.get(key)), "status payload contains a measurement field");
    }
    for (String key : new String[] {"valueText", "lastReadingText"}) {
      check("--".equals(payload.get(key)), "status payload contains a measurement or timestamp");
    }
    check(!payload.containsKey("recordedAtIso8601") && !payload.containsKey("serial"),
        "status payload contains time or identity");
    for (Object value : payload.values()) {
      check(!(value instanceof Number), "numeric status payload field");
      if (value instanceof String) check(!((String) value).matches(".*[0-9].*"),
          "status payload string contains a number");
    }
    try {
      payload.put("valueText", "synthetic-untrusted-value");
      throw new AssertionError("status payload accepts arbitrary data");
    } catch (UnsupportedOperationException expected) { }
  }

  private static LiveUpdateServiceLifecycle policy() {
    return new LiveUpdateServiceLifecycle("synthetic-process-one", new FakeClock());
  }

  private static final class FakeClock implements LiveUpdateServiceLifecycle.Clock {
    long elapsedMillis;
    public long nowMillis() { return elapsedMillis; }
  }

  private static final class Results implements LiveUpdateServiceLifecycle.Completion {
    final List<LiveUpdateServiceLifecycle.Failure> values = new ArrayList<>();
    public void complete(LiveUpdateServiceLifecycle.Failure failure) { values.add(failure); }
    boolean only(LiveUpdateServiceLifecycle.Failure failure) {
      return values.size() == 1 && values.get(0) == failure;
    }
  }

  private static void check(boolean value, String message) {
    if (!value) throw new AssertionError(message);
  }
}
