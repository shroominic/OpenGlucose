#!/usr/bin/env ruby

require "json"
require "tmpdir"

module UI
  class UserError < StandardError; end

  def self.user_error!(message)
    raise UserError, message
  end

  def self.success(_message); end
end

module Spaceship
  class Client
    USER_AGENT = "ReceiptStateMachineTest"
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

class RecordingTransport
  attr_reader :calls

  def initialize(response: nil, error: nil)
    @response = response
    @error = error
    @calls = []
  end

  def run_request(method, path, body, headers)
    @calls << [method, path, JSON.parse(body), headers]
    raise @error if @error

    @response
  end
end

Response = Struct.new(:status, :body)

successful_transport = RecordingTransport.new(
  response: Response.new(
    201,
    JSON.generate(
      "data" => {
        "type" => "buildBetaNotifications",
        "id" => "notification-id"
      }
    )
  )
)
successful_result = post_build_beta_notification_once(
  request_client: Struct.new(:client).new(successful_transport),
  build_id: "build-id"
)
assert(successful_transport.calls.length == 1, "success must use one transport call")
assert(successful_result[:status] == 201, "success status must be returned")
assert(
  successful_result[:body].dig("data", "id") == "notification-id",
  "success body must be parsed"
)

ambiguous_transport = RecordingTransport.new(error: IOError.new("ambiguous"))
begin
  post_build_beta_notification_once(
    request_client: Struct.new(:client).new(ambiguous_transport),
    build_id: "build-id"
  )
  raise "assertion failed: ambiguous transport failure must propagate"
rescue IOError => error
  assert(error.message == "ambiguous", "transport error must propagate unchanged")
end
assert(
  ambiguous_transport.calls.length == 1,
  "ambiguous failure must never enter an internal retry"
)

expected = {
  "schemaVersion" => 3,
  "appId" => "app-id",
  "bundleId" => "com.example.app",
  "buildId" => "build-id",
  "version" => "1.2.3",
  "buildNumber" => "45",
  "externalGroupId" => "external-group-id",
  "automaticInternalGroupId" => "internal-group-id",
  "associatedGroupIds" => ["external-group-id", "internal-group-id"],
  "externalTesterCount" => 23,
  "externalTesterIdsSha256" => "0" * 64,
  "sourceCommit" => "0123456789abcdef",
  "ipaSha256" => "1" * 64
}

Dir.mktmpdir("openglucose-receipt-test") do |directory|
  File.chmod(0o700, directory)
  receipt_path = File.join(directory, "notification.json")

  assert(
    notification_receipt_state(path: receipt_path, expected: expected) == :absent,
    "a missing receipt must be absent"
  )

  claim_id = create_notification_claim(path: receipt_path, expected: expected)
  pending = JSON.parse(File.read(receipt_path))
  assert(pending["status"] == "pending", "claim must start pending")
  assert(pending["claimId"] == claim_id, "claim identity must be durable")
  assert((File.stat(receipt_path).mode & 0o777) == 0o600, "claim mode must be 600")

  assert_user_error("claim is pending") do
    notification_receipt_state(path: receipt_path, expected: expected)
  end
  assert(
    require_pending_notification_claim(path: receipt_path, expected: expected) == claim_id,
    "the guarded continuation must recover only the exact pending claim"
  )
  File.chmod(0o400, receipt_path)
  assert_user_error("must have mode 600") do
    require_pending_notification_claim(path: receipt_path, expected: expected)
  end
  File.chmod(0o600, receipt_path)
  assert_user_error("does not match the exact release") do
    require_pending_notification_claim(
      path: receipt_path,
      expected: expected.merge("buildId" => "different-build")
    )
  end
  assert_user_error("claim already exists") do
    create_notification_claim(path: receipt_path, expected: expected)
  end

  complete_notification_claim(
    path: receipt_path,
    expected: expected,
    claim_id: claim_id,
    notification_id: "notification-id"
  )
  complete = JSON.parse(File.read(receipt_path))
  assert(complete["status"] == "complete", "confirmed claim must complete")
  assert(
    complete["notificationId"] == "notification-id",
    "completion must preserve the remote notification identity"
  )
  assert((File.stat(receipt_path).mode & 0o777) == 0o400, "receipt mode must be 400")
  assert(
    notification_receipt_state(path: receipt_path, expected: expected) == :complete,
    "an exact complete receipt must be verification-only"
  )
  assert_user_error("is not a pending claim") do
    require_pending_notification_claim(path: receipt_path, expected: expected)
  end
  assert_user_error("does not match the exact release") do
    notification_receipt_state(
      path: receipt_path,
      expected: expected.merge("buildId" => "different-build")
    )
  end

  second_path = File.join(directory, "second-notification.json")
  second_claim = create_notification_claim(path: second_path, expected: expected)
  assert_user_error("could not be confirmed complete") do
    complete_notification_claim(
      path: second_path,
      expected: expected,
      claim_id: "not-#{second_claim}",
      notification_id: "must-not-be-recorded"
    )
  end
  second = JSON.parse(File.read(second_path))
  assert(second["status"] == "pending", "a claim mismatch must stay pending")
  assert(!second.key?("notificationId"), "a claim mismatch must not complete")
end

puts "Notification receipt state-machine checks passed."
