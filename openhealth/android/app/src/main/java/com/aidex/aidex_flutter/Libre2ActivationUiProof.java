package com.aidex.aidex_flutter;

import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Read-only validation of the existing scalar activation journal schema. */
final class Libre2ActivationUiProof {
  private static final Set<String> KEYS = new HashSet<>(Arrays.asList(
      "schemaVersion", "operation", "attemptId", "state", "outcome",
      "nativeCaptureSessionId", "processSessionId", "versionCode", "lastUpdateTime",
      "captureSessionId", "patchInfoSha256", "plannedRequestSha256",
      "sourceFramCaptureSha256", "sourceEncryptedFramSha256", "lifecycle",
      "updatedAtUtc", "updatedAtMonotonicElapsedNanos"));

  private Libre2ActivationUiProof() {}

  static boolean verified(Map<String, Object> value, long nowMillis) {
    try {
      if (!value.keySet().equals(KEYS)
          || !Long.valueOf(1).equals(value.get("schemaVersion"))
          || !"target_unverified_gen1_activation".equals(value.get("operation"))
          || !"post_state_verified".equals(value.get("state"))
          || !"verified".equals(value.get("outcome"))
          || !"warmingUp".equals(value.get("lifecycle"))
          || !matches(value, "attemptId", "activation-[0-9a-f]{32}")
          || !matches(value, "captureSessionId", "session-[A-Za-z0-9-]{10,80}")
          || !matches(value, "nativeCaptureSessionId", "[A-Za-z0-9_-]{8,120}")
          || !matches(value, "processSessionId", "[A-Za-z0-9_-]{8,120}")) return false;
      for (String key : new String[] {"patchInfoSha256", "plannedRequestSha256",
          "sourceFramCaptureSha256", "sourceEncryptedFramSha256"}) {
        if (!matches(value, key, "[0-9a-f]{64}")) return false;
      }
      for (String key : new String[] {"versionCode", "lastUpdateTime", "updatedAtMonotonicElapsedNanos"}) {
        if (!(value.get(key) instanceof Long) || (Long) value.get(key) <= 0) return false;
      }
      final Object updated = value.get("updatedAtUtc");
      if (!(updated instanceof String)) return false;
      final long instant = Instant.parse((String) updated).toEpochMilli();
      return instant > 0 && instant <= nowMillis + 5000L;
    } catch (RuntimeException malformed) { return false; }
  }

  static boolean currentBindings(Map<String, Object> journal, Map<String, Object> source,
      String explicitAttemptId, String nativeSession, String processSession, long version,
      long lastUpdate, String sourceDigest) {
    return explicitAttemptId != null && explicitAttemptId.matches("[A-Za-z0-9_-]{8,120}")
        && Long.valueOf(2).equals(source.get("schemaVersion")) && source.size() == 18
        && "explicitLibre2Lifecycle".equals(source.get("sourceKind"))
        && explicitAttemptId.equals(source.get("explicitAttemptId"))
        && "libre2".equals(source.get("model")) && "gen1".equals(source.get("securityGeneration"))
        && "e007".equals(source.get("iso15693ManufacturerPrefix"))
        && nativeSession.equals(source.get("nativeCaptureSessionId"))
        && nativeSession.equals(journal.get("nativeCaptureSessionId"))
        && processSession != null && processSession.equals(source.get("processSessionId"))
        && processSession.equals(journal.get("processSessionId"))
        && Long.valueOf(version).equals(source.get("versionCode"))
        && Long.valueOf(version).equals(journal.get("versionCode"))
        && Long.valueOf(lastUpdate).equals(source.get("lastUpdateTime"))
        && Long.valueOf(lastUpdate).equals(journal.get("lastUpdateTime"))
        && sourceDigest.equals(journal.get("sourceFramCaptureSha256"))
        && journal.get("captureSessionId").equals(source.get("captureSessionId"))
        && journal.get("patchInfoSha256").equals(source.get("patchInfoSha256"));
  }

  private static boolean matches(Map<String, Object> value, String key, String expression) {
    return value.get(key) instanceof String && ((String) value.get(key)).matches(expression);
  }

  /** Strict bounded scalar JSON; duplicate keys (including escaped spellings) are rejected. */
  static Map<String, Object> parse(String input) {
    if (input == null || input.length() > 4096) throw new IllegalArgumentException();
    final Parser parser = new Parser(input);
    final Map<String, Object> value = new HashMap<>();
    parser.expect('{');
    if (!parser.consume('}')) {
      do {
        final String key = parser.string();
        if (value.containsKey(key)) throw new IllegalArgumentException();
        parser.expect(':');
        value.put(key, parser.scalar());
      } while (parser.consume(','));
      parser.expect('}');
    }
    parser.whitespace();
    if (parser.index != input.length()) throw new IllegalArgumentException();
    return value;
  }

  private static final class Parser {
    final String input;
    int index;
    Parser(String input) { this.input = input; }
    void whitespace() {
      while (index < input.length() && " \t\r\n".indexOf(input.charAt(index)) >= 0) index += 1;
    }
    boolean consume(char value) {
      whitespace();
      if (index < input.length() && input.charAt(index) == value) { index += 1; return true; }
      return false;
    }
    void expect(char value) { if (!consume(value)) throw new IllegalArgumentException(); }
    String string() {
      expect('"');
      final StringBuilder text = new StringBuilder();
      while (index < input.length()) {
        final char value = input.charAt(index++);
        if (value == '"') return text.toString();
        if (value < 0x20) throw new IllegalArgumentException();
        if (value != '\\') { text.append(value); continue; }
        if (index >= input.length()) throw new IllegalArgumentException();
        final char escaped = input.charAt(index++);
        switch (escaped) {
          case '"': case '\\': case '/': text.append(escaped); break;
          case 'b': text.append('\b'); break;
          case 'f': text.append('\f'); break;
          case 'n': text.append('\n'); break;
          case 'r': text.append('\r'); break;
          case 't': text.append('\t'); break;
          case 'u':
            if (index + 4 > input.length()) throw new IllegalArgumentException();
            final String digits = input.substring(index, index + 4);
            if (!digits.matches("[0-9a-fA-F]{4}")) throw new IllegalArgumentException();
            text.append((char) Integer.parseInt(digits, 16)); index += 4; break;
          default: throw new IllegalArgumentException();
        }
      }
      throw new IllegalArgumentException();
    }
    Object scalar() {
      whitespace();
      if (index >= input.length()) throw new IllegalArgumentException();
      if (input.charAt(index) == '"') return string();
      if (input.startsWith("null", index)) { index += 4; return null; }
      final int start = index;
      if (input.charAt(index) == '-') index += 1;
      while (index < input.length() && input.charAt(index) >= '0' && input.charAt(index) <= '9') index += 1;
      final String integer = input.substring(start, index);
      if (!integer.matches("-?(0|[1-9][0-9]*)")) throw new IllegalArgumentException();
      return Long.valueOf(integer);
    }
  }
}
