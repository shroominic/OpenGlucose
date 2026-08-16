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

GitHub Android releases use `.github/workflows/release-android.yml`. A new
strict `vMAJOR.MINOR.PATCH` tag starts the lane. An accountable owner can also
dispatch the same lane for an existing tag to rebuild the exact tagged source
and continue a hidden draft. It checks
that the tag matches the committed Flutter version and is reachable from
`main`, then enters the protected `android-release` environment. Missing or
partial signing secrets fail the run; the lane never warns and skips.

The lane builds once, verifies the release signature and configured certificate
fingerprint, package `com.openglucose.app`, committed version/build number,
non-debuggable state, required network permission, clean dependency state, and
SHA-256 digest. It creates GitHub build provenance, then creates or reuses a
hidden draft, attaches those exact APK bytes without overwriting an existing
asset, and re-fetches the remote asset to verify its name, state, size, and
SHA-256 digest. Only after that verification does it publish the release as a
stable Latest release. A build, signing, attestation, upload, or verification
failure leaves no new public release. Re-running a failed job can resume its
exact hidden draft with the same attested workflow artifact. A new dispatch can
reliably resume an assetless draft or an empty GitHub `starter` residue. An
uploaded asset from another run is accepted only if its name, size, and SHA-256
digest are byte-for-byte equal to the newly built and attested artifact; no
cross-run reproducibility is assumed. The lane removes a `starter` asset only
when it is in a hidden draft, is empty, and has no digest. Any other unexpected
or mismatched asset fails closed. The release workflow is the exclusive writer
for assets under these version tags. Releases are globally serialized, and
both the initial check and the final publish step require the target to remain
the greatest valid version tag on `main`. The lane finishes by verifying that
GitHub's public Latest route resolves to the exact release.

Private device candidates are not Releases. Deliver them through a bounded
private artifact channel with a unique build number, and never attach them to a
stable version tag.

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
disabled, and records its immutable ID. App Store Connect
omits `hasAccessToAllBuilds` for non-automatic external groups, which Fastlane
2.232.2 exposes as `nil`; only that external omission is accepted, while a
literal `true` remains rejected as automatic. External export uses the same exact
manual profile and certificate mapping as internal export, explicitly leaves
`testFlightInternalTestingOnly` disabled, and requires the processed build to
report `APP_STORE_ELIGIBLE`. After every deterministic source, dependency,
artifact, signature, provisioning-profile, review-metadata, and audience
preflight passes, it rechecks that audience and takes the immutable upload
attempt described below. `pilot` is the immediately following command and
uploads with distribution and automatic notification disabled. The lane then
associates the exact processed build through the external ID, proves that the
exact associated group set is the approved automatic internal group plus the
approved external group, rejects individually assigned testers, and pins the
external group's exact tester relationship set using an approved count plus
SHA-256 digest. It
requires every beta app localization to have a nonblank description and
feedback email, and requires one exact beta review detail with contact name,
email, phone, review notes, and an explicit demo-account flag (plus credentials
when the flag is true). These metadata checks run before upload and again before
submission. After submission, the lane refetches the exact build with its beta
review submission and accepts only Apple's pending, in-review, or approved
states. It rechecks both group memberships and the closed public-link state
after taking the durable notification claim and immediately before sending one
build-scoped tester notification.

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
finalization; use notify-only mode for the already finalized release.

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
mode first idempotently resumes association from the immutable finalized
upload attempt and provenance, then verifies the same clean commit, exact
build, closed public-link state, exact two-group association, and notification
state without building or uploading again. This also safely resumes a process
that stopped after final provenance publication but before association. A
pending-only upload attempt can never enter notify-only mode.
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
