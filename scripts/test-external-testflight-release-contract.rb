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
        attr_accessor :refetched, :last_options

        def get(**options)
          self.last_options = options
          refetched
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

ProvenanceApp = Struct.new(:id)
ProvenanceBuild = Struct.new(:id)
provenance_app = ProvenanceApp.new("app-resource-id")
provenance_build = ProvenanceBuild.new("build-resource-id")
source_commit = "a" * 40
ipa_sha256 = "b" * 64
expected = expected_upload_provenance(
  app: provenance_app,
  build: provenance_build,
  bundle_id: "com.example.app",
  version: "1.2.3",
  build_number: "45",
  source_commit: source_commit,
  ipa_sha256: ipa_sha256
)

Dir.mktmpdir("openglucose-upload-provenance-test") do |directory|
  File.chmod(0o700, directory)
  path = File.join(directory, "upload.json")
  create_upload_provenance(path: path, expected: expected)
  receipt = require_upload_provenance(
    path: path,
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
  assert(receipt["ipaSha256"] == ipa_sha256, "IPA digest must be recorded")
  assert((File.stat(path).mode & 0o777) == 0o400, "provenance must be immutable")

  assert_user_error("does not match the exact release") do
    require_upload_provenance(
      path: path,
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
      path: path,
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
      path: path,
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
    create_upload_provenance(path: path, expected: expected)
  end

  extra_field_path = File.join(directory, "extra-field.json")
  extra_field_receipt = receipt.merge("unreviewedField" => "must fail")
  File.write(extra_field_path, "#{JSON.generate(extra_field_receipt)}\n")
  File.chmod(0o400, extra_field_path)
  assert_user_error("unexpected schema") do
    require_upload_provenance(
      path: extra_field_path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end

  File.chmod(0o600, path)
  assert_user_error("must have mode 400") do
    require_upload_provenance(
      path: path,
      app: provenance_app,
      build: provenance_build,
      bundle_id: "com.example.app",
      version: "1.2.3",
      build_number: "45",
      source_commit: source_commit
    )
  end
end

puts "External TestFlight review and upload-provenance checks passed."
