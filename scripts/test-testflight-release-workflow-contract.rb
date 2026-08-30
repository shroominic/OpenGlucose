#!/usr/bin/env ruby

workflow_path = File.expand_path(
  "../.github/workflows/release-testflight.yml",
  __dir__
)
workflow = File.read(workflow_path)
release_script = File.read(
  File.expand_path("../openhealth/scripts/testflight.sh", __dir__)
)
fastfile = File.read(
  File.expand_path("../openhealth/fastlane/Fastfile", __dir__)
)
tag_verifier = File.read(
  File.expand_path("verify-testflight-release-tag.sh", __dir__)
)
release_docs = File.read(
  File.expand_path("../docs/releases.md", __dir__)
)

def assert(condition, message)
  raise "TestFlight workflow contract failed: #{message}" unless condition
end

def position!(text, fragment)
  position = text.index(fragment)
  raise "TestFlight workflow contract failed: missing #{fragment.inspect}" unless position

  position
end

assert(workflow.include?("name: TestFlight Release"), "workflow name must be stable")
assert(workflow.include?("workflow_dispatch:"), "a future stable tag must be manually deliverable")
assert(!workflow.include?("release:\n"), "a GitHub Release publication must not start TestFlight delivery")
assert(!workflow.include?("github.event.release"), "manual inputs must select every delivery phase")
assert(workflow.include?("- internal\n          - external"), "upload audience must be explicit")
assert(workflow.include?("- upload\n          - submit_review\n          - notify"), "delivery phases must be explicit")
assert(workflow.include?("group: openglucose-testflight-delivery"), "all TestFlight phases must be app-wide serialized")
assert(!workflow.include?("group: testflight-release-${{ inputs.release_tag }}"), "tag-specific concurrency must not permit parallel app delivery")
assert(workflow.include?("cancel-in-progress: false"), "Apple requests must not be cancelled")
assert(workflow.include?("testflight-internal-upload"), "internal upload must be protected")
assert(workflow.include?("testflight-external-upload"), "external upload must be protected")
assert(workflow.include?("testflight-external-review"), "review must be protected")
assert(workflow.include?("testflight-external-notify"), "notification must be protected")
assert(tag_verifier.include?("is still a draft"), "draft releases must be rejected")
assert(tag_verifier.include?("is a prerelease"), "prereleases must be rejected")
assert(tag_verifier.include?("compare/$candidate_commit...$main_commit"), "tag must be on main")
assert(tag_verifier.include?("releases?per_page=100"), "latest release must be selected from published releases")
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_UPLOAD_CLAIM=yes"), "external upload must stop after a claim")
assert(workflow.include?("TESTFLIGHT_RESUME_UPLOAD=yes"), "external pilot must use the claimed continuation")
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_UPLOAD=yes"), "external upload must stop before association")
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_REVIEW=yes"), "review must stop before notification")
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_NOTIFICATION_CLAIM=yes"), "notification must stop after its durable claim")
assert(workflow.include?("TESTFLIGHT_SEND_CLAIMED_NOTIFICATION=yes"), "notification must use the durable claim continuation")
assert(release_script.include?("--notify_external_testers false"), "pilot must not auto-notify")
assert(workflow.include?("actions/upload-artifact@"), "IPA and state must be retained privately")
assert(workflow.include?("actions/download-artifact@"), "follow-up phases must restore exact state")
assert(workflow.include?("actions/attest@"), "IPA provenance must be attested")
assert(workflow.include?("retention-days: 90"), "external state must outlive Apple processing")
assert(workflow.include?("run-id: ${{ inputs.upload_run_id }}"), "follow-up must name its upload evidence")
assert(workflow.include?("active_artifact_count"), "existing external boundary claims must block reruns")
assert(!workflow.include?("TESTFLIGHT_LEDGER"), "workflow must not need a second ledger or deploy key")
assert(!workflow.include?("contents: write"), "TestFlight delivery must not modify repository contents")
assert(!workflow.include?("notify_external_testers true"), "automatic tester notification is forbidden")
assert(fastfile.include?("lane :verify_external_upload_continuation"), "pilot continuation must verify the original upload claim")
assert(fastfile.include?("require_pending_notification_claim"), "notification continuation must verify the original claim")
assert(workflow.include?("expected_ref=\"refs/tags/$release_tag\""), "dispatch must bind its input to a tag ref")
assert(workflow.include?("test \"$WORKFLOW_REF\" = \"$expected_ref\""), "branch dispatch must fail before environment access")
assert(workflow.include?("test \"$WORKFLOW_REF_TYPE\" = tag"), "dispatch must require a tag ref type")
assert(workflow.include?("test \"$WORKFLOW_REF_PROTECTED\" = true"), "dispatch must require a protected tag ref")
assert(workflow.include?("test \"$WORKFLOW_DEFINITION_REF\" = \"$expected_workflow_ref\""), "workflow source must bind to the same tag")
assert(workflow.include?("TESTFLIGHT_REQUIRE_STABLE_TAG_FRESHNESS: \"yes\""), "workflow must enforce freshness inside release operations")
assert(tag_verifier.include?("GITHUB_REF_PROTECTED"), "tag verifier must reject unprotected refs")
assert(tag_verifier.include?("GITHUB_WORKFLOW_REF"), "tag verifier must bind the workflow definition ref")
assert(tag_verifier.include?("GITHUB_WORKFLOW_SHA"), "tag verifier must bind the workflow definition SHA")
assert(tag_verifier.include?("legacy tags are not eligible"), "tag verifier must reject tags predating this protocol")
assert(tag_verifier.include?("resolve_remote_tag_commit"), "tag verifier must resolve the remote tag object")
assert(tag_verifier.include?("latest_published_stable_release_tag"), "tag verifier must select the current published stable release")
assert(tag_verifier.include?("final_latest_release_tag"), "tag verifier must repeat the stable-release freshness check")
assert(!tag_verifier.include?("sort -V"), "tag verifier must remain portable to the macOS release runner")
assert(release_docs.include?("--ref vMAJOR.MINOR.PATCH"), "release docs must require dispatch from the tag ref")
assert(release_docs.include?("private `0.1.4 (26)` TestFlight candidate"), "release docs must keep the legacy candidate manual")

upload_claim = position!(workflow, "- name: Build, verify, and persist the external upload claim")
upload_claim_artifact = position!(workflow, "- name: Persist external upload claim before pilot")
upload_resume = position!(workflow, "- name: Resume persisted external upload claim and upload")
ipa_artifact = position!(workflow, "- name: Upload verified IPA workflow artifact")
attestation = position!(workflow, "- name: Attest verified IPA")
state = position!(workflow, "- name: Retain immutable external upload state")
assert(upload_claim < upload_claim_artifact, "claim must exist before it is persisted")
assert(upload_claim_artifact < upload_resume, "pilot must start only after its claim is durable")
assert(upload_resume < ipa_artifact, "IPA evidence must follow the verified upload")
assert(ipa_artifact < attestation, "retained IPA must be attested")
assert(attestation < state, "attestation must precede finalized external state")

post_approval_signing = position!(workflow, "- name: Revalidate protected stable tag after approval before signing")
assert(post_approval_signing < upload_claim, "post-approval tag freshness must precede signing")

signing_check = release_script.rindex("verify_stable_tag_freshness", release_script.index('echo "==> Restoring locked dependencies"'))
pilot_check = release_script.rindex("verify_stable_tag_freshness", release_script.index("fastlane pilot upload"))
notify_check = release_script.rindex("verify_stable_tag_freshness", release_script.index("fastlane ios notify_external_build"))
assert(signing_check, "stable tag freshness must run before signing")
assert(pilot_check, "stable tag freshness must run before pilot")
assert(notify_check, "stable tag freshness must run before notification")
assert(signing_check < release_script.index('echo "==> Restoring locked dependencies"'), "freshness must immediately precede release signing")
assert(pilot_check < release_script.index("fastlane pilot upload"), "freshness must precede pilot")
assert(notify_check < release_script.index("fastlane ios notify_external_build"), "freshness must precede notification")

notification_claim = position!(workflow, "- name: Create durable notification claim")
notification_claim_artifact = position!(workflow, "- name: Persist notification claim before send")
notification_send = position!(workflow, "- name: Send notification from persisted claim")
notification_receipt = position!(workflow, "- name: Retain completed notification receipt")
assert(notification_claim < notification_claim_artifact, "notification claim must exist before it is persisted")
assert(notification_claim_artifact < notification_send, "notification must send only after its claim is durable")
assert(notification_send < notification_receipt, "receipt must follow the single send attempt")

puts "TestFlight protected release workflow contract passed."
