# ADR 0004: Gate Windows support behind a portable preview

- Status: Proposed
- Date: 2026-08-16
- Owners: `@shroominic`

## Context

The Flutter app and AiDEX protocol can use a federated WinRT Bluetooth backend,
but the repository previously had no Windows runner, build lane, package, or
physical sensor evidence. A Windows executable also depends on adjacent Flutter
assets and native DLLs. Publishing one executable or treating a passing compile
as sensor support would create a broken and misleading release.

## Decision

Introduce Windows through a separate preview lane:

1. build from a clean, source-bound `windows-latest` checkout;
2. run deterministic package, transport, and UI tests;
3. produce a complete unsigned x64 portable ZIP with notices, source ref and
   commit, and SHA-256 evidence;
4. accept only an explicit existing strict release tag for a manual artifact
   run, resolve it to one immutable commit, and never auto-publish or modify a
   GitHub Release;
5. preserve the one-sensor, one-bond model and require an explicit transfer
   warning before Windows pairing; and
6. compile the pinned WinRT plugin with native identifier-bearing debug output
   disabled; and
7. withhold a Windows support or production-release claim until redacted
   physical evidence covers the critical sensor journey.

Signing and an installer are separate production decisions. An MSIX or other
installer must not be added until the release owner controls an appropriate
code-signing identity and can verify installation, update, and rollback.

## Alternatives considered

- **Ship only `OpenGlucose.exe`:** unusable because Flutter and plugin DLLs plus
  the `data` directory are required.
- **Publish the first CI output as a normal GitHub Release:** too early because
  physical Bluetooth behavior, signing, and recovery are unverified.
- **Require MSIX immediately:** gives a better install experience but needs
  certificate, identity, and update-channel decisions that are not available.
- **Use a second Windows-only BLE library:** duplicates transport code and
  increases dependency and behavior differences without current evidence.

## Consequences

- A Windows user can receive one complete, versioned ZIP for controlled testing
  after the Windows build succeeds. A maintainer can manually attach those
  verified bytes to the same stable release as a Windows Preview asset.
- SmartScreen can warn because the preview is unsigned.
- The mobile-only experimental AI persistence flow is hidden on Windows until
  a reviewed desktop database backend exists.
- Windows remains outside the supported platform list until the evidence gate
  is complete.
- Production publication remains fail-closed and separate from preview builds.

## Follow-up controls

- Record the first clean Windows workflow run and artifact checksum.
- Verify the Windows build applied the target-specific WinRT native-log
  suppression before accepting an artifact.
- Record identifier-free physical evidence for scan, pairing, GATT discovery,
  notification subscription, readings, reconnect, and transfer.
- Review the FlutterBluePlus license for the intended distribution model.
- Decide code signing, installer identity, update channel, and rollback before
  proposing Windows production distribution.
