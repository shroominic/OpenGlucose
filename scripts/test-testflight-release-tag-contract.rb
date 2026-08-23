#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "shellwords"
require "json"
require "tmpdir"

repo_root = File.expand_path("..", __dir__)
verifier = File.join(repo_root, "scripts/verify-testflight-release-tag.sh")
protocol_path = File.join(repo_root, ".github/testflight-release-protocol.json")
head = `git -C #{repo_root.shellescape} rev-parse HEAD`.strip

def assert(condition, message)
  raise "TestFlight tag contract failed: #{message}" unless condition
end

def expect_rejected(repo_root:, verifier:, tag:, environment:, message:)
  output, status = Open3.capture2e(
    environment,
    verifier,
    tag,
    `git -C #{repo_root.shellescape} rev-parse HEAD`.strip,
    chdir: repo_root
  )
  assert(!status.success?, "#{message}: verifier unexpectedly succeeded")
  assert(output.include?(message), "#{message}: verifier output was #{output.inspect}")
end

def expect_verified(repo_root:, verifier:, protocol_path:, head:, environment:)
  Dir.mktmpdir("openglucose-testflight-gh-") do |directory|
    call_log = File.join(directory, "calls.log")
    fake_gh = File.join(directory, "gh")
    fake_git = File.join(directory, "git")
    _, committed_protocol_status = Open3.capture2e(
      "git",
      "-C",
      repo_root,
      "cat-file",
      "-e",
      "#{head}:.github/testflight-release-protocol.json"
    )
    File.write(fake_gh, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      endpoint = ARGV.last
      File.open(ENV.fetch("FAKE_GH_CALL_LOG"), "a") { |file| file.puts(endpoint) }
      repository = "shroominic/OpenGlucose"
      head = ENV.fetch("FAKE_GH_HEAD")

      case endpoint
      when "repos/#{repository}/releases/tags/v9.9.9"
        puts JSON.generate(
          tag_name: "v9.9.9",
          draft: false,
          prerelease: false,
          published_at: "2026-08-24T00:00:00Z"
        )
      when "repos/#{repository}/git/ref/tags/v9.9.8", "repos/#{repository}/git/ref/tags/v9.9.9"
        puts JSON.generate(object: { sha: head, type: "commit" })
      when "repos/#{repository}/git/ref/heads/main"
        puts JSON.generate(object: { sha: head, type: "commit" })
      when "repos/#{repository}/compare/#{head}...#{head}"
        puts JSON.generate(status: "identical")
      when "repos/#{repository}/releases?per_page=100"
        puts JSON.generate([
          {
            tag_name: "v9.9.8",
            draft: false,
            prerelease: false,
            published_at: "2026-08-23T00:00:00Z"
          },
          {
            tag_name: "v9.9.9",
            draft: false,
            prerelease: false,
            published_at: "2026-08-24T00:00:00Z"
          }
        ])
      else
        abort "unexpected fake GitHub API endpoint: #{endpoint}"
      end
    RUBY
    File.chmod(0o755, fake_gh)
    unless committed_protocol_status.success?
      File.write(fake_git, <<~'SH')
        #!/usr/bin/env bash
        set -euo pipefail

        if [[ "$#" -eq 2 && "$1" == "show" && "$2" == "$FAKE_GIT_HEAD:.github/testflight-release-protocol.json" ]]; then
          exec /bin/cat "$FAKE_PROTOCOL_PATH"
        fi
        exec "$REAL_GIT" "$@"
      SH
      File.chmod(0o755, fake_git)
    end

    verifier_environment = {
      "FAKE_GH_CALL_LOG" => call_log,
      "FAKE_GH_HEAD" => head,
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "LC_ALL" => "C"
    }
    unless committed_protocol_status.success?
      verifier_environment.merge!(
        "FAKE_GIT_HEAD" => head,
        "FAKE_PROTOCOL_PATH" => protocol_path,
        "REAL_GIT" => "/usr/bin/git"
      )
    end

    output, status = Open3.capture2e(
      environment.merge(verifier_environment),
      verifier,
      "v9.9.9",
      head,
      chdir: repo_root
    )
    assert(status.success?, "valid protected future tag must verify: #{output}")
    assert(
      output.include?("Verified protected current stable TestFlight tag v9.9.9"),
      "valid protected future tag must report verification"
    )

    calls = File.readlines(call_log, chomp: true)
    release_list = "repos/shroominic/OpenGlucose/releases?per_page=100"
    tag_ref = "repos/shroominic/OpenGlucose/git/ref/tags/v9.9.9"
    assert(calls.count(release_list) == 2, "stable release selection must run again at the final boundary")
    assert(calls.count(tag_ref) >= 3, "remote release tag must be resolved again at the final boundary")
  end
end

assert(File.executable?(verifier), "tag verifier must be executable")
assert(head.match?(/\A[0-9a-f]{40}\z/), "test requires a full source SHA")
protocol = JSON.parse(File.read(protocol_path))
assert(protocol.fetch("schemaVersion") == 1, "protocol marker must use schema version 1")
assert(
  protocol.fetch("protocol") == "openglucose.testflight.tag-bound.v1",
  "protocol marker must opt in to the tag-bound workflow"
)
assert(
  protocol.fetch("workflow") == ".github/workflows/release-testflight.yml",
  "protocol marker must identify the TestFlight workflow"
)

expect_rejected(
  repo_root: repo_root,
  verifier: verifier,
  tag: "not-a-release-tag",
  environment: {},
  message: "release tag must be strict vMAJOR.MINOR.PATCH"
)

common_environment = {
  "GITHUB_REPOSITORY" => "shroominic/OpenGlucose",
  "GITHUB_REF" => "refs/heads/main",
  "GITHUB_REF_NAME" => "main",
  "GITHUB_REF_TYPE" => "branch",
  "GITHUB_REF_PROTECTED" => "true",
  "GITHUB_WORKFLOW_REF" => "shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/heads/main",
  "GITHUB_WORKFLOW_SHA" => head,
  "GH_TOKEN" => "not-used-by-this-negative-test"
}

expect_verified(
  repo_root: repo_root,
  verifier: verifier,
  protocol_path: protocol_path,
  head: head,
  environment: common_environment.merge(
    "GITHUB_REF" => "refs/tags/v9.9.9",
    "GITHUB_REF_NAME" => "v9.9.9",
    "GITHUB_REF_TYPE" => "tag",
    "GITHUB_WORKFLOW_REF" => "shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/tags/v9.9.9"
  )
)

expect_rejected(
  repo_root: repo_root,
  verifier: verifier,
  tag: "v9.9.9",
  environment: common_environment,
  message: "workflow execution ref (refs/heads/main) does not match refs/tags/v9.9.9"
)

expect_rejected(
  repo_root: repo_root,
  verifier: verifier,
  tag: "v9.9.9",
  environment: common_environment.merge(
    "GITHUB_REF" => "refs/tags/v9.9.9",
    "GITHUB_REF_NAME" => "v9.9.9",
    "GITHUB_REF_TYPE" => "tag",
    "GITHUB_REF_PROTECTED" => "false",
    "GITHUB_WORKFLOW_REF" => "shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/tags/v9.9.9"
  ),
  message: "workflow execution ref is not protected"
)

expect_rejected(
  repo_root: repo_root,
  verifier: verifier,
  tag: "v9.9.9",
  environment: common_environment.merge(
    "GITHUB_REF" => "refs/tags/v9.9.9",
    "GITHUB_REF_NAME" => "v9.9.9",
    "GITHUB_REF_TYPE" => "tag",
    "GITHUB_WORKFLOW_REF" => "shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/heads/main"
  ),
  message: "workflow definition ref (shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/heads/main) does not match"
)

expect_rejected(
  repo_root: repo_root,
  verifier: verifier,
  tag: "v9.9.9",
  environment: common_environment.merge(
    "GITHUB_REF" => "refs/tags/v9.9.9",
    "GITHUB_REF_NAME" => "v9.9.9",
    "GITHUB_REF_TYPE" => "tag",
    "GITHUB_WORKFLOW_REF" => "shroominic/OpenGlucose/.github/workflows/release-testflight.yml@refs/tags/v9.9.9",
    "GITHUB_WORKFLOW_SHA" => "0" * 40
  ),
  message: "workflow definition SHA (#{"0" * 40}) does not match expected commit"
)

puts "TestFlight tag-bound protocol negative contract checks passed."
