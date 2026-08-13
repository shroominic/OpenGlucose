# Releases

Releases are R3 changes. An accountable release owner approves the exact source
commit, version, artifact, target, tester/store audience, changelog, and rollback
path. Building or uploading does not imply permission to distribute.

## Readiness checklist

- The release worktree is a clean checkout of the reviewed integration commit.
- Required format, analysis, unit, integration, accessibility, security, and
  platform build checks pass with retained evidence.
- No unresolved P0/P1 finding or expired waiver exists.
- Privacy/store metadata, intended-use copy, supported devices/OS versions, and
  user-visible changes are current.
- Signing credentials are least privilege, supplied by the approved release
  environment, never printed, and removed immediately after use.
- Version/build numbers are committed and reviewed before the build. Release
  automation never edits them.
- Artifact signature, application/bundle ID, entitlements, source commit, and
  SHA-256 digest are verified and recorded.
- Rollback/revocation owner and communication path are confirmed.

## Android

Release signing is fail-closed. Provide `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` in
the local approved build environment. The GitHub `android-release` environment
instead requires exactly five environment secrets:
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`, and the independently reviewed
`ANDROID_SIGNING_CERT_SHA256`. Debug signing is never accepted for a release
artifact. Verify the APK/AAB signer, certificate fingerprint, package ID,
version, and checksum before upload.

GitHub beta releases use `.github/workflows/release-android-beta.yml`. Publishing
a GitHub prerelease with a strict `vMAJOR.MINOR.PATCH` tag triggers the lane. It
checks that the tag matches the committed Flutter version and is reachable from
`main`, then enters the protected `android-release` environment. Missing or
partial signing secrets fail the run; the lane never warns and skips.

The lane builds once, verifies the release signature and configured certificate
fingerprint, package `com.openglucose.app`, committed version/build number,
non-debuggable state, required network permission, clean dependency state, and
SHA-256 digest. It creates GitHub build provenance and attaches those exact APK
bytes without overwriting an existing asset. Because the release event occurs
after publication, a failed lane can temporarily leave an assetless prerelease;
do not delete, recreate, or overwrite it while the result is ambiguous.

The historical `v0.0.1+10` APK used the standard Android debug certificate.
`v0.1.0` intentionally starts the dedicated OpenGlucose beta signing lineage
and is not update-compatible with that APK. The old APK has no migration or
export path, and uninstalling it deletes its local data. Existing testers who
need that history must record it manually or defer upgrading; everyone else
must perform a clean install. Preserve the new keystore and its recovery
credentials: losing them prevents future in-place beta updates.

## TestFlight

`openhealth/scripts/testflight.sh` invokes the repository's exact Flutter/Dart
runtime verifier and enforces checked-in Fastlane, Xcode, and CocoaPods version
pins, a clean committed version, exact `RELEASE_COMMIT`, and both
`RELEASE_APPROVED=yes` and `DISTRIBUTE_EXTERNAL=yes`. It restores the locked
dependencies before the build and verifies the worktree and dependency inputs
again afterward. Before upload it verifies the main app and Live Activity
extension signatures, bundle IDs, versions, build numbers, teams, signed
application/team entitlements, and embedded App Store provisioning profiles. It
rejects every internal or external group that automatically receives all
builds, resolves exactly one existing external TestFlight group, and records
its immutable ID. It rechecks that audience immediately before it uploads
with distribution and automatic notification disabled, associates the exact
processed build through that ID, proves that no other external group is
associated, rejects every other internal/external group and individually
assigned tester on the build, and only then sends a single build-scoped tester
notification. Before that non-idempotent request, it durably creates a mode-600
`pending` claim containing the exact source commit, build, and group identity at
`TESTFLIGHT_NOTIFICATION_RECEIPT_PATH` outside the repository. A second process
cannot create the same claim. Only a confirmed response atomically transitions
it to a mode-400 `complete` receipt with the returned notification ID. The
notification request bypasses Fastlane's retrying request wrapper and makes
exactly one authenticated transport call. A matching complete receipt makes
later notify-only runs verification-only; it replaces
Apple's obsolete `didNotify` field as the one-shot control. The script creates
the Fastlane credential JSON in a private temporary directory and removes it on
exit. Before starting Fastlane, it rejects `.env`/`.env.default` files in the
app and Fastlane directories plus inherited variables that can alter Spaceship
authentication, team selection, endpoints, proxy/TLS behavior, transport, or
response logging. It uses the tester-relationship endpoint so the exclusivity
check never retrieves tester names or email addresses, and custom lanes disable
Spaceship's persistent request/response logger so group public links and
audience metadata are not retained under `/tmp`. It does not create groups,
install software, change the version, or pick an ambiguous artifact.

If external beta review is still pending, the command fails closed after the
approved ID association. After approval, rerun with
`TESTFLIGHT_NOTIFY_ONLY=yes` and the printed immutable
`TESTFLIGHT_GROUP_ID`; this mode verifies the same clean commit, exact build,
group ID/name, exclusive group association, and notification state without
uploading again. Concurrent notification runs are prohibited. A `pending`
claim, interrupted run, or ambiguous App Store Connect response blocks every
retry until the release owner reconciles the exact build. If the owner can prove
the request never reached App Store Connect, they may archive the pending claim
outside the active receipt path and restart; otherwise they must preserve it
and record the outcome without sending again. App Store Connect does not
provide an atomic group-ID-targeted notification, so release operators must
also prevent concurrent audience mutations during the final verification and
notification window.

The current native release-tool pins are Fastlane 2.232.2, Xcode 26.6, and
CocoaPods 1.16.2 in root version files. Updating one is an R3 release change:
review the new version, change the checked-in pin, and validate a signed app
plus extension rather than overriding the version from the release environment.

The script uploads and distributes externally, so run it only after the entire
checklist is approved. Use a separate build-only workflow when distribution is
not authorized.

Follow `docs/runbooks/release-rollback.md` for a bad or compromised release.
