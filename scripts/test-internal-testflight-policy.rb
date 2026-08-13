require "tmpdir"
require "digest"

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
  :public_link_enabled,
  :builds,
  keyword_init: true
) do
  def fetch_builds
    builds || []
  end
end
App = Struct.new(:groups) do
  def get_beta_groups
    groups
  end
end

TesterPage = Struct.new(:body)
TesterResponses = Struct.new(:pages) do
  def all_pages
    pages
  end
end
TesterClient = Struct.new(:ids_by_group) do
  def get(path, _params)
    group_id = path.split("/")[2]
    ids = ids_by_group.fetch(group_id)
    data = ids.map { |id| { "type" => "betaTesters", "id" => id } }
    TesterResponses.new([TesterPage.new("data" => data)])
  end
end

module Spaceship
  class ConnectAPI
    class << self
      attr_accessor :client
    end
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
  has_access_to_all_builds: true,
  public_link_enabled: false
)

approved_external = Group.new(
  id: "approved-external-group",
  name: "NS",
  is_internal_group: false,
  has_access_to_all_builds: false,
  public_link_enabled: false
)
external_tester_ids = %w[tester-a tester-b tester-c]
external_tester_digest = Digest::SHA256.hexdigest(
  external_tester_ids.sort.join("\n")
)
Spaceship::ConnectAPI.client = Struct.new(:test_flight_request_client).new(
  TesterClient.new({
    approved.id => ["approved-internal-tester"],
    approved_external.id => external_tester_ids
  })
)

assert(
  exact_external_group(
    app: App.new([approved, approved_external]),
    group_name: "NS",
    group_id: "approved-external-group",
    internal_group_name: "team",
    internal_group_id: "approved-group",
    internal_tester_id: "approved-internal-tester",
    external_tester_count: external_tester_ids.length.to_s,
    external_tester_ids_sha256: external_tester_digest
  ).equal?(approved_external),
  "external group was not selected alongside the automatic internal group"
)

assert_rejected("automatic external group") do
  automatic_external = Group.new(
    id: "automatic-external",
    name: "automatic",
    is_internal_group: false,
    has_access_to_all_builds: true,
    public_link_enabled: false
  )
  exact_external_group(
    app: App.new([approved, approved_external, automatic_external]),
    group_name: "NS",
    group_id: "approved-external-group",
    external_tester_count: external_tester_ids.length.to_s,
    external_tester_ids_sha256: external_tester_digest
  )
end

assert_rejected("unknown external classification") do
  unknown = Group.new(
    id: "unknown-external",
    name: "unknown",
    is_internal_group: nil,
    has_access_to_all_builds: nil,
    public_link_enabled: false
  )
  exact_external_group(
    app: App.new([approved, approved_external, unknown]),
    group_name: "NS",
    group_id: "approved-external-group",
    external_tester_count: external_tester_ids.length.to_s,
    external_tester_ids_sha256: external_tester_digest
  )
end

assert_rejected("external group public link") do
  linked_external = Group.new(
    id: "approved-external-group",
    name: "NS",
    is_internal_group: false,
    has_access_to_all_builds: false,
    public_link_enabled: true
  )
  exact_external_group(
    app: App.new([approved, linked_external]),
    group_name: "NS",
    group_id: "approved-external-group",
    external_tester_count: external_tester_ids.length.to_s,
    external_tester_ids_sha256: external_tester_digest
  )
end

assert_rejected("external tester membership changed") do
  exact_external_group(
    app: App.new([approved, approved_external]),
    group_name: "NS",
    group_id: "approved-external-group",
    external_tester_count: external_tester_ids.length.to_s,
    external_tester_ids_sha256: "0" * 64
  )
end

Build = Struct.new(:id)
build = Build.new("build-id")
approved.builds = [build]
approved_external.builds = [build]
associated = require_exact_external_association(
  app: App.new([approved, approved_external]),
  build: build,
  approved_group: approved_external,
  approved_internal_group_id: approved.id,
  required: true
)
assert(
  associated.map(&:id).sort == [approved.id, approved_external.id].sort,
  "external build audience was not exact"
)

assert_rejected("unexpected associated group") do
  unexpected = Group.new(
    id: "unexpected-group",
    name: "unexpected",
    is_internal_group: true,
    has_access_to_all_builds: false,
    public_link_enabled: false,
    builds: [build]
  )
  require_exact_external_association(
    app: App.new([approved, approved_external, unexpected]),
    build: build,
    approved_group: approved_external,
    approved_internal_group_id: approved.id,
    required: true
  )
end

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
