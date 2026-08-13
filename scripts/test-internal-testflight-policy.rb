require "tmpdir"

module UI
  class UserError < StandardError; end

  def self.user_error!(message)
    raise UserError, message
  end

  def self.success(*_arguments); end
end

def default_platform(*_arguments); end

def platform(*)
  yield
end

def desc(*_arguments); end
def lane(*_arguments); end

load File.expand_path("../openhealth/fastlane/Fastfile", __dir__)

Group = Struct.new(
  :id,
  :name,
  :is_internal_group,
  :has_access_to_all_builds,
  keyword_init: true
)
App = Struct.new(:groups) do
  def get_beta_groups
    groups
  end
end

def assert(condition, message)
  raise message unless condition
end

def assert_rejected(message)
  yield
  raise "expected rejection: #{message}"
rescue UI::UserError => error
  raise error if error.message.start_with?("expected rejection:")
end

approved = Group.new(
  id: "approved-group",
  name: "team",
  is_internal_group: true,
  has_access_to_all_builds: true
)

assert(
  exact_internal_automatic_group(
    app: App.new([approved]),
    group_name: "team",
    group_id: "approved-group"
  ).equal?(approved),
  "exact approved group was not selected"
)

assert_rejected("wrong group ID") do
  exact_internal_automatic_group(
    app: App.new([approved]),
    group_name: "team",
    group_id: "wrong-group"
  )
end

assert_rejected("unknown group classification") do
  unknown = Group.new(
    id: "unknown",
    name: "unknown",
    is_internal_group: nil,
    has_access_to_all_builds: true
  )
  exact_internal_automatic_group(
    app: App.new([approved, unknown]),
    group_name: "team",
    group_id: "approved-group"
  )
end

assert_rejected("automatic external group") do
  external = Group.new(
    id: "external",
    name: "external",
    is_internal_group: false,
    has_access_to_all_builds: true
  )
  exact_internal_automatic_group(
    app: App.new([approved, external]),
    group_name: "team",
    group_id: "approved-group"
  )
end

puts "Internal TestFlight policy helper checks passed."
