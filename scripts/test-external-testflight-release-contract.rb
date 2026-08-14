#!/usr/bin/env ruby

require "json"
require "tmpdir"

module UI
  class UserError < StandardError; end

  def self.user_error!(message)
    raise UserError, message
  end

  def self.success(*_arguments); end
end

module Spaceship
  class Client
    USER_AGENT = "ExternalReleaseContractTest"
  end

  class ConnectAPI
    class << self
      attr_accessor :review_detail_response

      def get_beta_app_review_detail(filter:, limit:)
        raise "unexpected review-detail filter" unless filter == { app: "app-id" }
        raise "unexpected review-detail limit" unless limit == 200

        review_detail_response
      end
    end
  end
end

def default_platform(*_arguments); end

def platform(*_arguments)
  yield
end

def desc(*_arguments); end

def lane(*_arguments); end

def assert(condition, message)
  raise "assertion failed: #{message}" unless condition
end

def assert_user_error(fragment)
  yield
  raise "assertion failed: expected UI.user_error! containing #{fragment.inspect}"
rescue UI::UserError => error
  assert(error.message.include?(fragment), "unexpected error: #{error.message}")
end

load File.expand_path("../openhealth/fastlane/Fastfile", __dir__)

Page = Struct.new(:models) do
  def to_models
    models
  end
end
Pages = Struct.new(:pages) do
  def all_pages
    pages
  end
end
Localization = Struct.new(:locale, :description, :feedback_email, keyword_init: true)
ReviewDetail = Struct.new(
  :contact_first_name,
  :contact_last_name,
  :contact_email,
  :contact_phone,
  :notes,
  :demo_account_required,
  :demo_account_name,
  :demo_account_password,
  keyword_init: true
)
ReviewApp = Struct.new(:id, :localizations) do
  def get_beta_app_localizations
    localizations
  end
end

localization = Localization.new(
  locale: "en-US",
  description: "A complete beta description",
  feedback_email: "feedback@example.test"
)
complete_detail = ReviewDetail.new(
  contact_first_name: "Release",
  contact_last_name: "Owner",
  contact_email: "owner@example.test",
  contact_phone: "+1 555 0100",
  notes: "Review the explicit sample-data flow without sensor hardware.",
  demo_account_required: false
)
app = ReviewApp.new("app-id", [localization])
Spaceship::ConnectAPI.review_detail_response = Pages.new([Page.new([complete_detail])])
assert(
  require_external_beta_review_metadata(app: app),
  "complete external review metadata must pass"
)

missing_description = Localization.new(
  locale: "en-US",
  description: " ",
  feedback_email: "feedback@example.test"
)
assert_user_error("description is missing") do
  require_external_beta_review_metadata(
    app: ReviewApp.new("app-id", [missing_description])
  )
end

missing_feedback = Localization.new(
  locale: "en-US",
  description: "A complete beta description",
  feedback_email: ""
)
assert_user_error("feedback email is missing") do
  require_external_beta_review_metadata(
    app: ReviewApp.new("app-id", [missing_feedback])
  )
end

missing_contact_fields = {
  contact_first_name: "contact first name is missing",
  contact_last_name: "contact last name is missing",
  contact_email: "contact email is missing",
  contact_phone: "contact phone is missing"
}
missing_contact_fields.each do |field, message|
  incomplete = complete_detail.dup
  incomplete[field] = ""
  Spaceship::ConnectAPI.review_detail_response = Pages.new([Page.new([incomplete])])
  assert_user_error(message) do
    require_external_beta_review_metadata(app: app)
  end
end

missing_notes = complete_detail.dup
missing_notes.notes = ""
Spaceship::ConnectAPI.review_detail_response = Pages.new([Page.new([missing_notes])])
assert_user_error("review notes is missing") do
  require_external_beta_review_metadata(app: app)
end

unknown_demo_flag = complete_detail.dup
unknown_demo_flag.demo_account_required = nil
Spaceship::ConnectAPI.review_detail_response = Pages.new([Page.new([unknown_demo_flag])])
assert_user_error("demo-account flag is unknown") do
  require_external_beta_review_metadata(app: app)
end

missing_demo_credentials = complete_detail.dup
missing_demo_credentials.demo_account_required = true
missing_demo_credentials.demo_account_name = ""
missing_demo_credentials.demo_account_password = "secret"
Spaceship::ConnectAPI.review_detail_response = Pages.new(
  [Page.new([missing_demo_credentials])]
)
assert_user_error("demo account name is missing") do
  require_external_beta_review_metadata(app: app)
end

Submission = Struct.new(:beta_review_state)
RefetchedBuild = Struct.new(:beta_app_review_submission)
RemoteBuild = Struct.new(:id)
module Spaceship
  class ConnectAPI
    class Build
      class << self
        attr_accessor :refetched, :last_options, :all_result, :last_all_options

        def get(**options)
          self.last_options = options
          refetched
        end

        def all(**options)
          self.last_all_options = options
          all_result || []
        end
      end
    end
  end
end

%w[WAITING_FOR_REVIEW IN_REVIEW APPROVED].each do |state|
  submission = Submission.new(state)
  Spaceship::ConnectAPI::Build.refetched = RefetchedBuild.new(submission)
  assert(
    require_external_beta_review_submission(build: RemoteBuild.new("build-id"))
      .equal?(submission),
    "#{state} must be an eligible external review state"
  )
  assert(
    Spaceship::ConnectAPI::Build.last_options == {
      build_id: "build-id",
      includes: "betaAppReviewSubmission"
    },
    "submission verification must refetch the exact build relationship"
  )
end
Spaceship::ConnectAPI::Build.refetched = RefetchedBuild.new(
  Submission.new("REJECTED")
)
assert_user_error("ineligible state") do
  require_external_beta_review_submission(build: RemoteBuild.new("build-id"))
end
Spaceship::ConnectAPI::Build.refetched = RefetchedBuild.new(nil)
assert_user_error("no external beta review submission") do
  require_external_beta_review_submission(build: RemoteBuild.new("build-id"))
end
Spaceship::ConnectAPI::Build.refetched = RefetchedBuild.new(
  Submission.new("APPROVED")
)
assert(
  require_approved_external_beta_review_submission(
    build: RemoteBuild.new("build-id")
  ).beta_review_state == "APPROVED",
  "completed notification verification must require approved beta review"
)
Spaceship::ConnectAPI::Build.refetched = RefetchedBuild.new(
  Submission.new("WAITING_FOR_REVIEW")
)
assert_user_error("is not approved") do
  require_approved_external_beta_review_submission(
    build: RemoteBuild.new("build-id")
  )
end

ProvenanceApp = Struct.new(:id)
ProvenanceBuild = Struct.new(:id)
provenance_app = ProvenanceApp.new("app-resource-id")
provenance_build = ProvenanceBuild.new("build-resource-id")
source_commit = "a" * 40
ipa_sha256 = "b" * 64

Spaceship::ConnectAPI::Build.all_result = []
assert(
  require_no_exact_build(
    app: provenance_app,
    version: "1.2.3",
    build_number: "45"
  ),
  "claim preflight must accept an absent exact build"
)
assert(
  Spaceship::ConnectAPI::Build.last_all_options == {
    app_id: "app-resource-id",
    version: "1.2.3",
    build_number: "45",
    platform: "IOS",
    processing_states: "PROCESSING,FAILED,INVALID,VALID"
  },
  "claim preflight must query the exact app, version, build, and platform"
)
Spaceship::ConnectAPI::Build.all_result = [ProvenanceBuild.new("existing")]
assert_user_error("already contains TestFlight build") do
  require_no_exact_build(
    app: provenance_app,
    version: "1.2.3",
    build_number: "45"
  )
end
Spaceship::ConnectAPI::Build.all_result = []

attempt_identity = {
  app: provenance_app,
  bundle_id: "com.example.app",
  version: "1.2.3",
  build_number: "45",
  source_commit: source_commit,
  ipa_sha256: ipa_sha256
}
assert_user_error("must be distinct") do
  require_external_upload_paths_distinct(
    attempt_path: "/secure/release.json",
    provenance_path: "/secure/release.json"
  )
end
assert_user_error("temporary namespace") do
  require_external_upload_paths_distinct(
    attempt_path: "/secure/attempt.json",
    provenance_path: "/secure/attempt.json.tmp.operator"
  )
end

Dir.mktmpdir("openglucose-upload-provenance-test") do |directory|
  File.chmod(0o700, directory)
  attempt_path = File.join(directory, "upload-attempt.json")
  provenance_path = File.join(directory, "upload-provenance.json")
  continuation_path = File.join(directory, "continuation-token")
  assert(
    external_upload_file_state(
      attempt_path: attempt_path,
      provenance_path: provenance_path
    ) == :absent,
    "new external build must begin with no upload state"
  )
  create_upload_attempt(
    path: attempt_path,
    continuation_token_path: continuation_path,
    expected: attempt_identity
  )
  assert(
    (File.stat(attempt_path).mode & 0o777) == 0o400,
    "upload attempt must be immutable"
  )
  assert(
    (File.stat(continuation_path).mode & 0o777) == 0o600,
    "uninterrupted finalization token must stay private"
  )
  assert(
    external_upload_file_state(
      attempt_path: attempt_path,
      provenance_path: provenance_path
    ) == :pending,
    "attempt without final provenance must be pending"
  )
  upload_attempt = require_upload_attempt(
    path: attempt_path,
    **attempt_identity,
    continuation_token_path: continuation_path
  )
  assert(
    upload_attempt[:receipt]["appId"] == "app-resource-id",
    "attempt must bind the App Store Connect app"
  )
  assert(
    upload_attempt[:receipt]["ipaSha256"] == ipa_sha256,
    "attempt must bind the locally verified IPA digest"
  )
  assert(
    !File.binread(attempt_path).include?(load_upload_continuation_token(continuation_path)),
    "attempt must retain only the continuation-token digest"
  )
  wrong_continuation_path = File.join(directory, "wrong-continuation-token")
  File.write(wrong_continuation_path, "#{'f' * 64}\n")
  File.chmod(0o600, wrong_continuation_path)
  assert_user_error("does not match this attempt") do
    require_upload_attempt(
      path: attempt_path,
      **attempt_identity,
      continuation_token_path: wrong_continuation_path
    )
  end
  tampered_attempt_path = File.join(directory, "tampered-attempt.json")
  tampered_attempt = upload_attempt[:receipt].merge("unreviewedField" => true)
  File.write(tampered_attempt_path, "#{JSON.generate(tampered_attempt)}\n")
  File.chmod(0o400, tampered_attempt_path)
  assert_user_error("unexpected schema") do
    require_upload_attempt(
      path: tampered_attempt_path,
      **attempt_identity
    )
  end
  assert_user_error("without finalized provenance") do
    require_external_upload_file_state(
      attempt_path: attempt_path,
      provenance_path: provenance_path,
      expected: :complete
    )
  end
  assert_user_error("without finalized provenance") do
    require_upload_provenance(
      path: provenance_path,
      upload_attempt_path: attempt_path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end
  assert_user_error("cannot be resumed") do
    require_external_upload_file_state(
      attempt_path: attempt_path,
      provenance_path: provenance_path,
      expected: :pending
    )
  end

  expected = expected_upload_provenance(
    app: provenance_app,
    build: provenance_build,
    bundle_id: "com.example.app",
    version: "1.2.3",
    build_number: "45",
    source_commit: source_commit,
    ipa_sha256: ipa_sha256,
    upload_attempt: upload_attempt
  )
  create_upload_provenance(path: provenance_path, expected: expected)
  receipt = require_upload_provenance(
    path: provenance_path,
    upload_attempt_path: attempt_path,
    app: provenance_app,
    build: provenance_build,
    bundle_id: "com.example.app",
    version: "1.2.3",
    build_number: "45",
    source_commit: source_commit,
    ipa_sha256: ipa_sha256
  )
  assert(receipt["appId"] == "app-resource-id", "app resource ID must be recorded")
  assert(
    receipt["buildId"] == "build-resource-id",
    "build resource ID must be recorded"
  )
  assert(
    receipt["buildAudienceType"] == "APP_STORE_ELIGIBLE",
    "final provenance must bind an App Store-eligible build"
  )
  assert(receipt["ipaSha256"] == ipa_sha256, "IPA digest must be recorded")
  assert(
    receipt["uploadAttemptId"] == upload_attempt[:receipt]["attemptId"],
    "provenance must bind the exact immutable attempt"
  )
  assert(
    receipt["uploadAttemptSha256"] == upload_attempt[:sha256],
    "provenance must bind the exact attempt bytes"
  )
  assert(
    (File.stat(provenance_path).mode & 0o777) == 0o400,
    "provenance must be immutable"
  )
  assert(
    Dir.children(directory).grep(/\.tmp\./).empty?,
    "successful publication must clean private temporary files"
  )
  original_bytes = File.binread(provenance_path)

  assert_user_error("does not match the exact release") do
    require_upload_provenance(
      path: provenance_path,
      upload_attempt_path: attempt_path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: "c" * 40
    )
  end
  assert_user_error("does not match the exact release") do
    require_upload_provenance(
      path: provenance_path,
      upload_attempt_path: attempt_path,
      app: provenance_app,
      build: ProvenanceBuild.new("different-build-id"),
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end
  assert_user_error("does not match the exact release") do
    require_upload_provenance(
      path: provenance_path,
      upload_attempt_path: attempt_path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit,
      ipa_sha256: "d" * 64
    )
  end
  assert_user_error("already exists") do
    create_upload_provenance(path: provenance_path, expected: expected)
  end
  assert(
    File.binread(provenance_path) == original_bytes,
    "no-overwrite publication must preserve the existing receipt"
  )
  assert(
    Dir.children(directory).grep(/\.tmp\./).empty?,
    "failed no-overwrite publication must clean only its own temporary file"
  )

  collision_path = File.join(directory, "collision.json")
  collision_suffix = "c" * 32
  private_collision = "#{collision_path}.tmp.#{Process.pid}.#{collision_suffix}"
  File.write(private_collision, "operator-owned collision\n")
  original_hex = SecureRandom.method(:hex)
  SecureRandom.define_singleton_method(:hex) { |_length| collision_suffix }
  begin
    assert_user_error("temporary-path collision") do
      create_upload_provenance(path: collision_path, expected: expected)
    end
  ensure
    SecureRandom.define_singleton_method(:hex) do |*arguments|
      original_hex.call(*arguments)
    end
  end
  assert(
    !File.exist?(collision_path),
    "a temporary collision must not publish final provenance"
  )
  assert(
    File.read(private_collision) == "operator-owned collision\n",
    "a temporary collision must not delete an inode it does not own"
  )

  extra_field_attempt = File.join(directory, "extra-field-attempt.json")
  File.write(extra_field_attempt, File.binread(attempt_path))
  File.chmod(0o400, extra_field_attempt)
  extra_field_path = File.join(directory, "extra-field-provenance.json")
  extra_field_receipt = receipt.merge("unreviewedField" => "must fail")
  File.write(extra_field_path, "#{JSON.generate(extra_field_receipt)}\n")
  File.chmod(0o400, extra_field_path)
  assert_user_error("unexpected schema") do
    require_upload_provenance(
      path: extra_field_path,
      upload_attempt_path: extra_field_attempt,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end

  File.chmod(0o600, provenance_path)
  assert_user_error("must have mode 400") do
    require_upload_provenance(
      path: provenance_path,
      upload_attempt_path: attempt_path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end

  final_only_attempt = File.join(directory, "missing-attempt.json")
  final_only_provenance = File.join(directory, "final-only.json")
  File.write(final_only_provenance, "{}\n")
  File.chmod(0o400, final_only_provenance)
  assert_user_error("without its immutable attempt claim") do
    require_external_upload_file_state(
      attempt_path: final_only_attempt,
      provenance_path: final_only_provenance,
      expected: :complete
    )
  end
  assert_user_error("normal upload reruns are blocked") do
    require_external_upload_file_state(
      attempt_path: attempt_path,
      provenance_path: provenance_path,
      expected: :absent
    )
  end
end

Dir.mktmpdir("openglucose-concurrent-upload-attempt-test") do |directory|
  File.chmod(0o700, directory)
  attempt_path = File.join(directory, "attempt.json")
  child_pids = 2.times.map do |index|
    fork do
      begin
        create_upload_attempt(
          path: attempt_path,
          continuation_token_path: File.join(directory, "token-#{index}"),
          expected: attempt_identity
        )
        exit!(0)
      rescue UI::UserError
        exit!(10)
      end
    end
  end
  statuses = child_pids.map { |pid| Process.wait2(pid).last.exitstatus }.sort
  assert(statuses == [0, 10], "exactly one concurrent attempt must win")
  original_attempt = File.binread(attempt_path)
  assert((File.stat(attempt_path).mode & 0o777) == 0o400, "winning claim is immutable")
  assert(
    Dir.children(directory).grep(/\.tmp\./).empty?,
    "concurrent attempt publication must clean owned temporary inodes"
  )
  assert_user_error("already exists") do
    create_upload_attempt(
      path: attempt_path,
      continuation_token_path: File.join(directory, "third-token"),
      expected: attempt_identity
    )
  end
  assert(
    File.binread(attempt_path) == original_attempt,
    "a later attempt must never overwrite the winning claim"
  )
  assert(
    !File.exist?(File.join(directory, "third-token")),
    "a losing attempt must clean only its own continuation token"
  )
end

puts "External TestFlight review, upload-attempt, and provenance checks passed."
