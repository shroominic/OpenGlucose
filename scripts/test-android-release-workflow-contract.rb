#!/usr/bin/env ruby

workflow_path = File.expand_path(
  "../.github/workflows/release-android.yml",
  __dir__
)
workflow = File.read(workflow_path)

def assert(condition, message)
  raise "Android release workflow contract failed: #{message}" unless condition
end

def position!(text, fragment)
  position = text.index(fragment)
  raise "Android release workflow contract failed: missing #{fragment.inspect}" if position.nil?

  position
end

assert(workflow.include?("name: Android Release"), "workflow name must be stable")
assert(workflow.include?("push:\n    tags:"), "version tags must start the lane")
assert(workflow.include?("workflow_dispatch:"), "an exact tag must be resumable")
assert(!workflow.include?("release:\n"), "a public release must not start the lane")
assert(!workflow.include?("github.event.release"), "release visibility must not gate the build")
assert(workflow.include?("group: android-release"), "all versions must be serialized")
assert(workflow.include?("environment: android-release"), "signing must stay protected")
assert(workflow.include?("persist-credentials: false"), "checkout credentials must not persist")
assert(workflow.include?("git merge-base --is-ancestor"), "tag must be on main")
assert(workflow.include?("draft: true"), "release must start hidden")
assert(workflow.include?("prerelease: false"), "published release must be stable")
assert(workflow.include?('make_latest: "true"'), "published release must become Latest")
assert(workflow.include?("asset_count"), "existing assets must be classified")
assert(workflow.include?("Release has unexpected extra assets"), "extra assets must fail closed")
assert(workflow.scan("greatest eligible release tag").length == 2, "version order must be checked twice")
assert(workflow.include?("asset_state\" = starter"), "incomplete uploads must be recoverable")
assert(workflow.include?("Only a hidden draft may discard an incomplete asset"), "starter cleanup must stay private")
assert(workflow.include?("Refusing to discard a non-empty starter asset"), "starter cleanup must require zero bytes")
assert(workflow.include?("Refusing to discard a starter asset with a digest"), "starter cleanup must require no digest")
assert(workflow.include?("releases/assets/$asset_id"), "starter cleanup must target one asset")
assert(workflow.include?("sha256:$EXPECTED_SHA256"), "remote digest must be exact")
assert(workflow.include?("releases/latest"), "the public Latest route must be verified")
assert(!workflow.include?("--clobber"), "an existing asset must never be overwritten")

build = position!(workflow, "- name: Build signed release APK")
attest = position!(workflow, "- name: Create build provenance attestation")
draft = position!(workflow, "create_payload=")
upload = position!(workflow, "https://uploads.github.com/repos/")
remote_verify = position!(workflow, 'release_json=$(gh api "repos/$GITHUB_REPOSITORY/releases/$release_id")')
publish = position!(workflow, "publish_payload=")
publish_call = position!(workflow, "gh api --method PATCH")

assert(build < attest, "artifact must be built before attestation")
assert(attest < draft, "artifact must be attested before any draft is created")
assert(draft < upload, "draft must exist before upload")
assert(upload < remote_verify, "uploaded asset must be re-fetched")
assert(remote_verify < publish, "remote asset must be verified before publication")
assert(publish < publish_call, "stable payload must precede its final PATCH")

puts "Android draft-first release workflow contract passed."
