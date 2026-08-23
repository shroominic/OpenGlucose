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

def assert(condition, message)
  raise "TestFlight workflow contract failed: #{message}" unless condition
end

def position!(text, fragment)
  position = text.index(fragment)
  raise "TestFlight workflow contract failed: missing #{fragment.inspect}" unless position

  position
end

assert(workflow.include?("name: TestFlight Release"), "workflow name must be stable")
assert(workflow.include?("workflow_dispatch:"), "an existing stable tag must be manually deliverable")
assert(!workflow.include?("release:\n"), "a GitHub Release publication must not start TestFlight delivery")
assert(!workflow.include?("github.event.release"), "manual inputs must select every delivery phase")
assert(workflow.include?("- internal\n          - external"), "upload audience must be explicit")
assert(workflow.include?("- upload\n          - submit_review\n          - notify"), "delivery phases must be explicit")
assert(workflow.include?("group: testflight-release-"), "each tag must be serialized")
assert(workflow.include?("cancel-in-progress: false"), "Apple requests must not be cancelled")
assert(workflow.include?("testflight-internal-upload"), "internal upload must be protected")
assert(workflow.include?("testflight-external-upload"), "external upload must be protected")
assert(workflow.include?("testflight-external-review"), "review must be protected")
assert(workflow.include?("testflight-external-notify"), "notification must be protected")
assert(workflow.include?("test \"$(jq -r '.draft'"), "draft releases must be rejected")
assert(workflow.include?("test \"$(jq -r '.prerelease'"), "prereleases must be rejected")
assert(workflow.include?("git merge-base --is-ancestor"), "tag must be on main")
assert(workflow.include?("releases?per_page=100"), "latest release must be selected from published releases")
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

notification_claim = position!(workflow, "- name: Create durable notification claim")
notification_claim_artifact = position!(workflow, "- name: Persist notification claim before send")
notification_send = position!(workflow, "- name: Send notification from persisted claim")
notification_receipt = position!(workflow, "- name: Retain completed notification receipt")
assert(notification_claim < notification_claim_artifact, "notification claim must exist before it is persisted")
assert(notification_claim_artifact < notification_send, "notification must send only after its claim is durable")
assert(notification_send < notification_receipt, "receipt must follow the single send attempt")

puts "TestFlight protected release workflow contract passed."
