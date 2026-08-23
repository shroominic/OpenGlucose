#!/usr/bin/env ruby

workflow_path = File.expand_path(
  "../.github/workflows/release-testflight.yml",
  __dir__
)
workflow = File.read(workflow_path)
release_script = File.read(
  File.expand_path("../openhealth/scripts/testflight.sh", __dir__)
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
assert(workflow.include?("release:\n    types:\n      - published"), "stable releases must start internal delivery")
assert(workflow.include?("workflow_dispatch:"), "an existing stable tag must be manually deliverable")
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
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_UPLOAD=yes"), "upload must stop before association")
assert(workflow.include?("TESTFLIGHT_STOP_AFTER_REVIEW=yes"), "review must stop before notification")
assert(release_script.include?("--notify_external_testers false"), "pilot must not auto-notify")
assert(workflow.include?("actions/upload-artifact@"), "IPA and state must be retained privately")
assert(workflow.include?("actions/download-artifact@"), "follow-up phases must restore exact state")
assert(workflow.include?("actions/attest@"), "IPA provenance must be attested")
assert(workflow.include?("retention-days: 90"), "external state must outlive Apple processing")
assert(workflow.include?("run-id: ${{ inputs.upload_run_id }}"), "follow-up must name its upload evidence")
assert(!workflow.include?("TESTFLIGHT_LEDGER"), "workflow must not need a second ledger or deploy key")
assert(!workflow.include?("contents: write"), "TestFlight delivery must not modify repository contents")
assert(!workflow.include?("notify_external_testers true"), "automatic tester notification is forbidden")

upload = position!(workflow, "- name: Build, verify, and upload the exact IPA")
ipa_artifact = position!(workflow, "- name: Upload verified IPA workflow artifact")
attestation = position!(workflow, "- name: Attest verified IPA")
state = position!(workflow, "- name: Retain immutable external upload state")
assert(upload < ipa_artifact, "IPA must exist before it is retained")
assert(ipa_artifact < attestation, "retained IPA must be attested")
assert(attestation < state, "attestation must precede retained external state")

puts "TestFlight protected release workflow contract passed."
