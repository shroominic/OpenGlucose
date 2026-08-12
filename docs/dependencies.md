# Dependency policy

Dependencies increase maintenance, privacy, security, licensing, build, and
compatibility risk. OpenGlucose uses Dart Pub, CocoaPods, Gradle, Flutter SDK
components, and platform frameworks; preserve those native ecosystems rather
than adding a competing package manager.

## Ownership and approval

The author proposing a dependency owns its initial evidence. `@shroominic` is
the current accountable dependency and release owner. A manifest change must
explain:

- the user or engineering problem and why existing code/dependencies do not
  solve it;
- packages, native transitive components, permissions, network destinations,
  background behavior, code generation, and build scripts introduced;
- maintenance activity, supported platforms, release cadence, and exit cost;
- license and notice obligations;
- security advisories and provenance of the selected release; and
- data accessed or transmitted, retention, credentials, and failure behavior.

Dependencies touching health data, BLE, native permissions, cryptography,
network/AI providers, secure storage, signing, analytics, or background
execution are high risk and require the relevant privacy/security or platform
review.

## Version and lockfile policy

- Pin the repository's supported Flutter toolchain and Java version.
- Commit the application lockfile (`openhealth/pubspec.lock`) so app builds use
  a reviewed dependency graph.
- Keep library-package Pub lockfiles uncommitted so packages are tested as
  libraries against their declared constraints. Test lower or wider bounds
  explicitly before claiming that support.
- Commit the iOS `Podfile.lock` for the application and keep Gradle wrapper and
  plugin versions under review. Pin the Gradle distribution URL with its
  official `distributionSha256Sum`; update both in the same review.
- Dependabot covers Pub, GitHub Actions, and the Android Gradle manifests.
  Gradle-wrapper distribution updates remain an explicit maintainer review
  because the wrapper URL is executable build infrastructure.
- Use frozen/enforced resolution in CI after bootstrap and fail on unexplained
  lockfile drift.
- Avoid Git, path-outside-workspace, unbounded, prerelease, or mutable-source
  dependencies without an explicit, time-bounded exception.

Generated lockfiles and manifests must change together in a focused commit.
Never hand-edit a resolved lockfile to imitate a package-manager result.

## Adding or updating a dependency

1. Start from a clean isolated worktree and record the current dependency graph.
2. Review the direct package and important transitives using primary registry,
   repository, advisory, and license sources.
3. Prefer the smallest maintained dependency with a compatible license and no
   unnecessary permissions, services, telemetry, or build-time downloads.
4. Update through the native package manager; inspect manifest, lockfile,
   platform project, permission, entitlement, and generated-registration diffs.
5. Run package-wide checks plus affected native builds and integration tests.
6. Exercise timeout, denial, unavailable-service, malformed-input, and rollback
   behavior for third-party integrations.
7. Update documentation, license inventory/notice material, compatibility notes,
   and changelogs as appropriate.
8. Record the rollback version and any migration constraint in the pull request.

Do not combine a dependency upgrade with unrelated behavior or broad formatting.

## Automated updates and advisories

Automated dependency pull requests are review prompts, not automatic approval.
Group only changes with the same owner and verification path. Keep high-risk
native, cryptographic, BLE, storage, network, and release tooling updates
separate.

Dependency and secret scans should begin as visible reports with an accountable
owner. A vulnerability triage records reachability, severity, affected
versions, mitigation, upgrade/patch plan, and due date. Do not permanently
ignore an advisory without a documented owner, justification, compensating
control, and expiry.

## Licenses and distribution

The repository's MIT License covers OpenGlucose-owned source only. Before an
external binary or source distribution, generate the license inventory from the
exact resolved dependency graph and preserve all required notices. Review
missing, unknown, nonstandard, reciprocal, source-available, or platform SDK
terms with the intended distribution model; do not infer compatibility from a
package's popularity.

See [NOTICE.md](../NOTICE.md) for distribution guidance and
[docs/compatibility.md](compatibility.md) for dependency-related support-floor
changes.
