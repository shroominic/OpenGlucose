# ADR 0003: Use fail-closed, source-bound platform releases

- Status: Accepted
- Date: 2026-08-12
- Owners: `@shroominic`

## Context

OpenGlucose produces Android and iOS applications that process sensitive data
and communicate with sensors. A successful Flutter build is not proof that an
artifact is correctly signed, uses the intended source, includes the right
entitlements, or was uploaded through a least-privilege path. Existing release
experiments do not yet establish those properties and external store settings
cannot be enforced by repository documentation alone.

## Decision

Release lanes must fail closed. No externally distributed artifact is approved
until the platform lane:

1. starts from an immutable reviewed source commit and clean dependency graph;
2. runs the required checks for the application and every workspace package;
3. builds with an explicit release configuration and the intended application
   identifiers, versions, entitlements, and platform floor;
4. signs using short-lived or tightly scoped credentials supplied only to a
   protected release environment;
5. verifies the produced signature, package identity, version, and provenance;
6. retains checksums and evidence linking the artifact to its source commit;
7. uploads the exact verified artifact rather than rebuilding it; and
8. records approval, target, staged rollout or pause mechanism, and recovery
   path.

Pull-request workflows never receive production signing or publishing secrets.
Android and iOS are separate release lanes because their signing, entitlement,
store, and rollback models differ. Repository workflows and scripts express
intent; protected environments, secrets, app-store roles, and branch rules are
external controls and remain unverified until an authorized owner checks them.

## Alternatives considered

- **Local maintainer scripts as the primary release path:** flexible but
  difficult to reproduce, attest, and review.
- **Build a fresh artifact during upload:** convenient, but breaks the link
  between tested and published bytes.
- **Share signing credentials with pull-request CI:** reduces workflow
  complexity but exposes high-impact secrets to untrusted code.
- **Treat passing platform builds as release readiness:** misses signing,
  entitlement, store, provenance, and recovery controls.

## Consequences

- External publishing stays suspended while signature/provenance validation is
  incomplete.
- Maintainers need protected platform environments and least-privilege roles.
- Release evidence must identify commit, dependency locks, toolchain, artifact
  digest, signature, approver, and destination.
- Store rollback is usually a new release or rollout pause rather than deletion;
  recovery plans must reflect platform reality.
- Local development and unsigned CI builds remain available without release
  credentials.

## Follow-up controls

- Implement and test platform-specific release runbooks.
- Remove debug signing from Android release artifacts and verify signatures.
- Configure authenticated Xcode signing on a clean runner and verify the IPA.
- Pin release tools and isolate temporary credentials.
- Have a repository administrator verify protected branches, environments,
  approval rules, secret permissions, and store roles before publishing.
