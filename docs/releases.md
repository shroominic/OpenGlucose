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
Repository immutable releases must remain disabled for this post-publication
attachment lane. If immutable releases are enabled, replace it with a
draft-first build-and-attach flow before publishing any release.

The historical `v0.0.1+10` APK used the standard Android debug certificate.
`v0.1.0` intentionally starts the dedicated OpenGlucose beta signing lineage
and is not update-compatible with that APK. The old APK has no migration or
export path, and uninstalling it deletes its local data. Existing testers who
need that history must record it manually or defer upgrading; everyone else
must perform a clean install. Preserve the new keystore and its recovery
credentials: losing them prevents future in-place beta updates.

## TestFlight

`openhealth/scripts/testflight.sh` invokes the repository's exact Flutter/Dart
runtime verifier and supports separate fail-closed `external` (default) and
`internal` audience modes. Both enforce checked-in Fastlane, Xcode, and
CocoaPods version pins, a clean committed version, exact `RELEASE_COMMIT`, and
both `RELEASE_APPROVED=yes` and the matching distribution gate. It restores the
locked dependencies before the build and verifies the worktree and dependency
inputs again afterward. Before upload it verifies the main app and Live
Activity extension signatures, bundle IDs, versions, build numbers, teams,
signed application/team entitlements, and embedded App Store provisioning
profiles. It also rejects any IPA containing `Runner.debug.dylib`, preventing
the untethered debug-engine crash seen in earlier test packages.

Internal mode requires `TESTFLIGHT_MODE=internal`, an immutable
`TESTFLIGHT_GROUP_ID`, and `DISTRIBUTE_INTERNAL=yes`. It requires exactly one
automatic internal group with the approved name and ID, exactly one tester in
that group with its approved immutable relationship ID, no automatic external
group, and no other automatic internal group. A headless internal export also
requires the canonical App Store provisioning-profile UUID for each exact
bundle ID in `APP_STORE_PROFILE_UUID` and
`LIVE_ACTIVITY_APP_STORE_PROFILE_UUID`, plus the exact 40-character Apple
Distribution certificate SHA-1 in `IOS_DISTRIBUTION_CERTIFICATE_SHA1`. The
generated Xcode ExportOptions use manual signing, map both targets to those
explicit UUIDs, and set `testFlightInternalTestingOnly`; Xcode therefore cannot
silently choose a stale profile or rely on a signed-in Apple account, and the
artifact cannot later be distributed through external TestFlight or the App
Store. The processed build must report `INTERNAL_ONLY`.
It uploads with external distribution, beta review submission, and external
notification disabled. After Apple finishes processing, it verifies that the
exact valid build is associated only with that one internal group and has no
individually assigned testers, then repeats the audience checks before success.
It never calls the external association or notification lanes.

External mode requires both `DISTRIBUTE_EXTERNAL=yes` and
`DISTRIBUTE_INTERNAL=yes` because Apple's approved automatic internal group
also receives every App Store-eligible build. It pins that group and its sole
tester by immutable IDs, rejects any other automatic group, resolves exactly
one existing non-automatic external group, requires its public link to be
disabled, and records its immutable ID. External export uses the same exact
manual profile and certificate mapping as internal export, explicitly leaves
`testFlightInternalTestingOnly` disabled, and requires the processed build to
report `APP_STORE_ELIGIBLE`. It rechecks that audience immediately before it
uploads with distribution and automatic notification disabled, associates the
exact processed build through the external ID, proves that the exact associated
group set is the approved automatic internal group plus the approved external
group, rejects individually assigned testers, and pins the external group's
exact tester relationship set using an approved count plus SHA-256 digest. It
rechecks both group memberships and the closed public-link state after taking
the durable notification claim and immediately before sending one build-scoped
tester notification. Before that non-idempotent request, it durably creates a
mode-600 `pending` claim containing the exact source commit, build, both
authorized group IDs, the associated group-ID set, and the approved external
tester count/digest at
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
`TESTFLIGHT_GROUP_ID` plus the exact automatic internal group/tester IDs; this
mode verifies the same clean commit, exact build, closed public-link state,
exact two-group association, and notification state without uploading again.
Concurrent notification runs are prohibited. A `pending`
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

Resolve the two profile UUIDs from freshly downloaded App Store distribution
profiles after decoding them with `security cms -D`; do not substitute profile
names. Resolve the certificate SHA-1 from the approved valid `Apple
Distribution` identity in the release keychain. Verify that each profile is
unexpired, belongs to the exact team and bundle ID, includes
`beta-reports-active`, excludes device provisioning and debugger attachment,
and that the main-app profile includes HealthKit. Export these three values only
in the private release shell; do not add real signing identifiers or profiles
to `.env`, logs, or the repository.

The external mode distributes externally, so run it only after that entire
audience is approved. Internal mode still uploads a real build to its automatic
internal audience and therefore requires explicit release approval.

Follow `docs/runbooks/release-rollback.md` for a bad or compromised release.
