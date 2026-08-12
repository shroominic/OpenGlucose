# Contributing to OpenGlucose

Thanks for helping build OpenGlucose — an open-source, local-first health and
wellness app. This guide covers local setup, the dev toolchain, and the commit
conventions. The Flutter app lives in `openhealth/`; shared Dart/BLE logic lives
in `packages/` (see the [root README](README.md) for the architecture).

## Prerequisites

- **Flutter** (stable, matching `openhealth/pubspec.yaml` → `environment.flutter`).
  Verify with `flutter --version`. Run `flutter doctor` to check your toolchain.
- **Node.js** — only used by the commit-message hook (commitlint runs via `npx`).
- **Lefthook** — the git-hook manager. The setup script installs it for you.

## Setup

```bash
git clone https://github.com/shroominic/OpenGlucose
cd OpenGlucose

# Install git hooks (formatting, analysis, tests, commit-msg linting).
make setup          # or: ./scripts/install-hooks.sh

# Fetch Dart/Flutter dependencies for the app.
cd openhealth && flutter pub get
```

`make setup` installs Lefthook (via Homebrew or `go install` if it is missing),
then runs `lefthook install` to wire up the hooks in `.git/hooks`.

## Everyday commands

Run these from the repo root via `make`, or directly inside `openhealth/`:

| Task                 | `make`           | Direct (`cd openhealth`)                          |
| -------------------- | ---------------- | ------------------------------------------------- |
| Format code          | `make format`    | `dart format .`                                   |
| Check formatting     | `make format-check` | `dart format --output=none --set-exit-if-changed .` |
| Static analysis/lint | `make analyze`   | `flutter analyze`                                 |
| Run tests            | `make test`      | `flutter test`                                    |
| Everything (like CI) | `make check`     | —                                                 |

Run the app with `cd openhealth && flutter run` (on web and in widget tests a
demo driver stands in for real BLE, so the UI is verifiable without hardware).

## Linting & formatting

- **Lints:** we extend [`very_good_analysis`](https://pub.dev/packages/very_good_analysis)
  in `openhealth/analysis_options.yaml` — a strong, opinionated set that catches
  bugs and enforces consistent style. A handful of rules are temporarily
  baselined (with inline comments) because of pre-existing violations; re-enable
  and clean them up one at a time (most are auto-fixable). Run `dart fix --apply`
  in `openhealth/` to apply automatic fixes.
- **Formatting:** `dart format` is the single source of truth. Keep code
  formatted; the pre-commit hook rejects unformatted staged Dart files.

## Git hooks (Lefthook)

Configured in [`lefthook.yml`](lefthook.yml) and installed by `make setup`:

- **pre-commit** — `dart format --set-exit-if-changed` on staged Dart files and
  `flutter analyze` over the app. Fast; blocks unformatted or failing code.
- **commit-msg** — `commitlint` enforces Conventional Commits (see below).
- **pre-push** — `flutter test` must pass before you push.

Test a hook without committing: `lefthook run pre-commit`.
Bypass in a genuine emergency only: `git commit --no-verify` (then fix forward).

## Commit messages (Conventional Commits)

Format: `<type>(<scope>): <subject>`, enforced by
[`commitlint.config.mjs`](commitlint.config.mjs).

- **types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`.
- **scopes** (optional, a warning if unknown): `app`, `ble`, `aidex`, `core`,
  `ui`, `ios`, `android`, `docs`, `deps`, `ci`, `repo`.

Examples:

```
feat(app): add glucose trend arrow to dashboard
fix(aidex): handle truncated history packets during sync
chore(deps): bump flutter_blue_plus to 8.2.1
```

## Pull requests

1. Branch off `main`: `feature/<scope>`, `fix/<scope>`, `chore/<scope>`, or
   `docs/<scope>`.
2. Keep changes focused and include tests for new or changed behavior.
3. Ensure `make check` passes (format + analyze + test) before opening the PR.
4. Use a Conventional Commit title and describe what changed and why.
