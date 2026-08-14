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
`internal` audience modes. External mode is split into the explicit
`TESTFLIGHT_EXTERNAL_OPERATION` values `upload`, `submit_review`,
`notify_testers`, and the read-only `verify_notification` completion phase so
upload, beta-review submission, and one-shot notification can be resumed
independently. Both modes enforce checked-in Fastlane, Xcode, and
CocoaPods version pins, a clean committed version, exact `RELEASE_COMMIT`, and
both `RELEASE_APPROVED=yes` and the matching distribution gate. It restores the
locked dependencies before the build and verifies the worktree and dependency
inputs again afterward. Before upload it verifies the main app and Live
Activity extension signatures, bundle IDs, versions, build numbers, teams,
signed application/team entitlements, and embedded App Store provisioning
profiles. It also rejects any IPA containing `Runner.debug.dylib`, preventing
the untethered debug-engine crash seen in earlier test packages.

The GitHub-hosted TestFlight workflow applies only to releases after `v0.1.1`
whose upload attempt starts in its private append-only ledger. It must not adopt
or re-upload the existing `v0.1.0` build 18: that build's attempt and provenance
were created by the approved local release process. Build 18 remains on its
preserved local resume path for export-compliance resolution, beta-review
submission, and notification. The `v0.1.1` tag also predates the hosted
workflow and is intentionally rejected; start hosted uploads with a later
committed version and build number after this workflow is merged and configured.

The iOS app intentionally omits `ITSAppUsesNonExemptEncryption`; the bundle
must not self-declare an exemption that has not been reviewed. Before approving
an external TestFlight build, the Account Holder must answer Apple's export-
compliance questions in App Store Connect from a current review of the
cryptography shipped by the app and its dependencies. The release owner must
record the export-compliance determination, responder, date, supporting
evidence, and any classification or authorization identifiers in the private
release record. An unresolved or unrecorded determination blocks external beta
approval and tester notification. Do not add the Info.plist key merely to
suppress the classification step.

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
disabled, and records its immutable ID. App Store Connect omits
`hasAccessToAllBuilds` for non-automatic external groups, which Fastlane
2.232.2 exposes as `nil`; only that external omission is accepted, while a
literal `true` remains rejected as automatic.

The `upload` operation is the default for legacy local invocations. It uses the
same exact manual profile and certificate mapping as internal export,
explicitly leaves `testFlightInternalTestingOnly` disabled, and requires the
processed build to report `APP_STORE_ELIGIBLE`. After every deterministic
source, dependency, artifact, signature, provisioning-profile,
review-metadata, and audience preflight passes, it rechecks that audience and
takes the immutable upload attempt described below. The configured durable
ledger hook runs before `pilot`, which uploads with distribution, review
submission, and automatic notification disabled. After Apple processing, the
operation records and persists final provenance, then exits successfully. It
never associates the external group, submits beta review, or notifies testers.

The `submit_review` operation requires the finalized upload attempt and
provenance, performs no build or upload, idempotently associates the exact
processed build through the approved external group ID, and submits it for
external beta review before exiting. It proves that the associated group set is
the approved automatic internal group plus the approved external group,
rejects individually assigned testers, and pins the external group's exact
tester relationship set using an approved count plus SHA-256 digest. It
requires every beta app localization to have a nonblank description and
feedback email, and one exact beta review detail with contact name, email,
phone, review notes, and an explicit demo-account flag (plus credentials when
the flag is true). After submission, it refetches the exact build with its beta
review submission and accepts only Apple's pending, in-review, or approved
states. Export-compliance questions or beta review can therefore be resolved
without rebuilding or re-uploading.

The `notify_testers` operation also requires finalized upload records and does
not build or upload. It idempotently revalidates association and review state,
then rechecks both group memberships and the closed public-link state after
taking the durable notification claim and immediately before sending one
build-scoped tester notification.

`verify_notification` is permitted only for a restored mode-400
`notification-complete` ledger record. It validates the receipt's exact schema
and release identity before any App Store Connect access, then reads and
rechecks the exact app, valid build, upload provenance, approved submission,
disabled automatic-notification flag, group/tester audience, eligible external
state, and complete notification receipt. It performs no association, PATCH,
POST, ledger write, build, or upload. The hosted workflow derives this phase
automatically when a `notify_testers` request finds an already complete record;
it is not an operator-selected retry.

The external lane requires `TESTFLIGHT_UPLOAD_PROVENANCE_PATH` in a mode-700
directory outside the repository and deterministically derives the immutable
attempt path by appending `.attempt`; there is no separately configurable
attempt location. After every deterministic preflight and immediately before
`pilot`, the claim lane asks App Store Connect for the exact app, iOS version,
and build number across every processing state and aborts if any build already
exists. It then publishes a mode-400 immutable attempt containing only the app
and bundle IDs, version/build, source commit, locally verified IPA SHA-256,
random attempt ID, continuation-token digest, and UTC claim time. Publication
uses a uniquely named, fsynced same-directory inode and an atomic no-overwrite
hard link. Official runs for the same provenance record therefore contend on
one path: one claim wins and no process can replace it. Managed attempt,
provenance, notification, `.tmp.*`, and `.complete.*` path namespaces may not
collide.

`TESTFLIGHT_LEDGER_HOOK` may point to an absolute, executable,
repository-owned command when release state must also survive the machine that
runs Fastlane. The command is invoked synchronously, without a shell, as
`HOOK persist KIND ABSOLUTE_RECORD_PATH`. Stable kinds are `upload_attempt`,
`upload_provenance`, `notification_pending`, and `notification_complete`. A
configured hook failure stops the phase. The upload-attempt hook runs after the
local claim and before `pilot`; the provenance hook runs after final local
provenance and before upload-phase success; the pending notification hook runs
after the local claim and before any audience recheck or notification POST; and
the complete hook runs after the confirmed local completion. The protected
GitHub release workflow requires this hook. It remains optional for an approved
local runner whose mode-700 release directory is itself the durable system of
record.

Only the same uninterrupted shell has the private, mode-600 continuation token
needed to finalize the claim. After `pilot` returns and Apple processing
succeeds, the lane resolves exactly one valid build, rechecks its
`APP_STORE_ELIGIBLE` audience type, and atomically publishes mode-400 final
provenance. The final record binds the exact App Store Connect build ID and
audience type to the attempt ID and SHA-256 of the immutable attempt bytes, as
well as the app/bundle, version/build, source commit, IPA digest, and UTC
recording time. Successful state permanently retains both records. Association
and notification require both, validate their schemas/modes/binding, and
revalidate the exact remote build. A normal upload rerun is blocked even after
finalization; use `submit_review` or `notify_testers` for the already finalized
release. Use `verify_notification` only for a restored complete notification.

An attempt without final provenance means the non-idempotent upload boundary is
ambiguous. Every restarted automation mode must stop before App Store Connect
access. Do not delete, archive, auto-recover, or infer success from the remote
version/build lookup; preserve the claim, record an incident, and cut a new
build number. Final provenance without its attempt is also inconsistent and
blocks automation. App Store Connect exposes neither the uploaded IPA digest
nor an uploader-owned delivery identity, so an out-of-band uploader racing
between the absence query and `pilot` cannot be cryptographically excluded.
The release owner must enforce exclusive upload authority for the app/version/
build during this window. Apple also does not attest the local IPA SHA-256; it
identifies the bytes supplied by this uninterrupted claimed invocation.
Before the non-idempotent notification request, the lane durably
creates a mode-600 `pending` claim containing the exact source commit, build, both
authorized group IDs, the associated group-ID set, and the approved external
tester count/digest plus the provenance-bound IPA SHA-256 at
`TESTFLIGHT_NOTIFICATION_RECEIPT_PATH` outside the repository. A second process
cannot create the same claim. Only a confirmed response atomically transitions
it to a mode-400 `complete` receipt with the returned notification ID. The
notification request bypasses Fastlane's retrying request wrapper and makes
exactly one authenticated transport call. A matching complete receipt makes
later local notification checks verification-only, while hosted automation
routes the completed state to `verify_notification`. The receipt replaces
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

Run `submit_review` only after the Account Holder records the export-compliance
determination. If Apple review is pending, that operation succeeds after
recording the eligible pending submission state; it does not notify. After
approval, run `notify_testers` with the same immutable `TESTFLIGHT_GROUP_ID`,
automatic internal group/tester IDs, upload attempt, and provenance. It first
idempotently resumes association, then verifies the same clean commit, exact
build, closed public-link state, exact two-group association, and notification
state without building or uploading again. A pending-only upload attempt can
never enter either post-upload operation. For compatibility, an older local
invocation that omits `TESTFLIGHT_EXTERNAL_OPERATION` still maps
`TESTFLIGHT_NOTIFY_ONLY=no` to `upload` and `yes` to `notify_testers`; release
automation must set the explicit operation.
Concurrent notification runs are prohibited. A `pending`
claim, interrupted run, or ambiguous App Store Connect response blocks every
retry until the release owner reconciles the exact build. A hosted
`notification-pending` ledger ref is immutable: it may never be archived,
deleted, replaced, or retried, even if later evidence suggests the request did
not arrive. Hosted automation must preserve it as a permanent incident record
and must not send another notification for that build. An approved persistent
local process may use its separately documented manual reconciliation path;
that exception never applies to the hosted ledger. App Store Connect does not
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
