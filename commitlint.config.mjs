/**
 * Conventional Commits enforcement for OpenGlucose.
 * Format: <type>(<scope>): <subject>
 *
 * Scopes map to the app/package areas so history stays navigable. Run by the
 * `commit-msg` git hook (see lefthook.yml). Scope is a warning, not an error,
 * so it does not block ad-hoc commits while still nudging toward consistency.
 */
export default {
  extends: ["@commitlint/config-conventional"],
  rules: {
    "type-enum": [
      2,
      "always",
      [
        "feat",
        "fix",
        "docs",
        "style",
        "refactor",
        "perf",
        "test",
        "build",
        "ci",
        "chore",
        "revert",
      ],
    ],
    "scope-enum": [
      1,
      "always",
      [
        "app", // openhealth/ Flutter app
        "ble", // cgm_ble / cgm_ble_flutter packages
        "aidex", // cgm_aidex package
        "core", // cgm_core package
        "ui",
        "ios",
        "android",
        "docs",
        "deps",
        "ci",
        "repo",
      ],
    ],
    "body-max-line-length": [0, "always"],
  },
};
