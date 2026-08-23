#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'TestFlight release tag validation failed: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

[[ "$#" -eq 2 ]] || fail 'usage: verify-testflight-release-tag.sh <tag> <source-commit>'
release_tag="$1"
expected_commit="$2"

[[ "$release_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "release tag must be strict vMAJOR.MINOR.PATCH (found $release_tag)"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'expected source commit must be a full lowercase Git SHA-1'
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
: "${GITHUB_REF:?missing GITHUB_REF}"
: "${GITHUB_REF_NAME:?missing GITHUB_REF_NAME}"
: "${GITHUB_REF_TYPE:?missing GITHUB_REF_TYPE}"
: "${GITHUB_REF_PROTECTED:?missing GITHUB_REF_PROTECTED}"
: "${GITHUB_WORKFLOW_REF:?missing GITHUB_WORKFLOW_REF}"
: "${GITHUB_WORKFLOW_SHA:?missing GITHUB_WORKFLOW_SHA}"
: "${GH_TOKEN:?missing GH_TOKEN}"

require_command git
require_command gh
require_command jq

expected_ref="refs/tags/$release_tag"
expected_workflow_ref="$GITHUB_REPOSITORY/.github/workflows/release-testflight.yml@$expected_ref"
[[ "$GITHUB_REF" == "$expected_ref" ]] || fail "workflow execution ref ($GITHUB_REF) does not match $expected_ref"
[[ "$GITHUB_REF_NAME" == "$release_tag" ]] || fail "workflow execution ref name ($GITHUB_REF_NAME) does not match $release_tag"
[[ "$GITHUB_REF_TYPE" == 'tag' ]] || fail "workflow execution ref type ($GITHUB_REF_TYPE) is not tag"
[[ "$GITHUB_REF_PROTECTED" == 'true' ]] || fail 'workflow execution ref is not protected by a GitHub ruleset or tag-protection rule'
[[ "$GITHUB_WORKFLOW_REF" == "$expected_workflow_ref" ]] || fail "workflow definition ref ($GITHUB_WORKFLOW_REF) does not match $expected_workflow_ref"

head_commit=$(git rev-parse HEAD)
[[ "$head_commit" == "$expected_commit" ]] || fail "checked-out source ($head_commit) does not match expected commit ($expected_commit)"
[[ "$GITHUB_WORKFLOW_SHA" == "$expected_commit" ]] || fail "workflow definition SHA ($GITHUB_WORKFLOW_SHA) does not match expected commit ($expected_commit)"
git cat-file -e "$expected_commit^{commit}" || fail "expected source commit is not a commit ($expected_commit)"

protocol_path='.github/testflight-release-protocol.json'
protocol_json=$(git show "$expected_commit:$protocol_path") || fail "release source does not contain $protocol_path; legacy tags are not eligible"
[[ "$(jq -r '.schemaVersion // empty' <<<"$protocol_json")" == '1' ]] || fail 'release source has an unsupported TestFlight protocol schema'
[[ "$(jq -r '.protocol // empty' <<<"$protocol_json")" == 'openglucose.testflight.tag-bound.v1' ]] || fail 'release source does not opt in to the tag-bound TestFlight protocol'
[[ "$(jq -r '.workflow // empty' <<<"$protocol_json")" == '.github/workflows/release-testflight.yml' ]] || fail 'release source identifies an unexpected TestFlight workflow'

resolve_remote_tag_commit() {
  local tag="$1"
  local ref_json
  local object_sha
  local object_type
  local tag_json
  local depth=0

  ref_json=$(gh api --method GET "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag") || fail "could not resolve remote tag $tag"
  object_sha=$(jq -r '.object.sha // empty' <<<"$ref_json")
  object_type=$(jq -r '.object.type // empty' <<<"$ref_json")
  [[ "$object_sha" =~ ^[0-9a-f]{40}$ ]] || fail "remote tag $tag has no valid object SHA"

  while [[ "$object_type" == 'tag' ]]; do
    depth=$((depth + 1))
    (( depth <= 4 )) || fail "remote tag $tag has unexpected annotation depth"
    tag_json=$(gh api --method GET "repos/$GITHUB_REPOSITORY/git/tags/$object_sha") || fail "could not dereference annotated remote tag $tag"
    object_sha=$(jq -r '.object.sha // empty' <<<"$tag_json")
    object_type=$(jq -r '.object.type // empty' <<<"$tag_json")
    [[ "$object_sha" =~ ^[0-9a-f]{40}$ ]] || fail "annotated remote tag $tag has no valid target SHA"
  done

  [[ "$object_type" == 'commit' ]] || fail "remote tag $tag does not resolve to a commit"
  printf '%s\n' "$object_sha"
}

release_json=$(gh api --method GET "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag") || fail "stable GitHub Release is missing for $release_tag"
[[ "$(jq -r '.tag_name // empty' <<<"$release_json")" == "$release_tag" ]] || fail "GitHub Release does not bind to $release_tag"
[[ "$(jq -r '.draft' <<<"$release_json")" == 'false' ]] || fail "GitHub Release $release_tag is still a draft"
[[ "$(jq -r '.prerelease' <<<"$release_json")" == 'false' ]] || fail "GitHub Release $release_tag is a prerelease"
[[ -n "$(jq -r '.published_at // empty' <<<"$release_json")" ]] || fail "GitHub Release $release_tag has not been published"

remote_source_commit=$(resolve_remote_tag_commit "$release_tag")
[[ "$remote_source_commit" == "$expected_commit" ]] || fail "remote tag $release_tag no longer resolves to $expected_commit"

resolve_remote_main_commit() {
  local main_ref_json
  local main_commit

  main_ref_json=$(gh api --method GET "repos/$GITHUB_REPOSITORY/git/ref/heads/main") || fail 'could not resolve remote main'
  main_commit=$(jq -r '.object.sha // empty' <<<"$main_ref_json")
  [[ "$main_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'remote main has no valid commit SHA'
  printf '%s\n' "$main_commit"
}

is_ancestor_of_main() {
  local candidate_commit="$1"
  local main_commit="$2"
  local comparison_json
  local comparison_status

  comparison_json=$(gh api --method GET "repos/$GITHUB_REPOSITORY/compare/$candidate_commit...$main_commit") || fail "could not compare $candidate_commit with remote main"
  comparison_status=$(jq -r '.status // empty' <<<"$comparison_json")
  [[ "$comparison_status" == 'behind' || "$comparison_status" == 'identical' ]]
}

is_newer_release_tag() {
  local candidate_tag="$1"
  local current_tag="$2"
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch

  [[ "$candidate_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  candidate_major="${BASH_REMATCH[1]}"
  candidate_minor="${BASH_REMATCH[2]}"
  candidate_patch="${BASH_REMATCH[3]}"
  [[ "$current_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  current_major="${BASH_REMATCH[1]}"
  current_minor="${BASH_REMATCH[2]}"
  current_patch="${BASH_REMATCH[3]}"

  if (( 10#$candidate_major != 10#$current_major )); then
    (( 10#$candidate_major > 10#$current_major ))
  elif (( 10#$candidate_minor != 10#$current_minor )); then
    (( 10#$candidate_minor > 10#$current_minor ))
  else
    (( 10#$candidate_patch > 10#$current_patch ))
  fi
}

latest_published_stable_release_tag() {
  local main_commit="$1"
  local published_tags
  local candidate_tag
  local candidate_commit
  local latest_tag=

  published_tags=$(mktemp)
  gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" | jq -r '.[] | select(.draft == false and .prerelease == false and .published_at != null) | .tag_name' > "$published_tags"
  while IFS= read -r candidate_tag; do
    [[ "$candidate_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
    candidate_commit=$(resolve_remote_tag_commit "$candidate_tag")
    if is_ancestor_of_main "$candidate_commit" "$main_commit"; then
      if [[ -z "$latest_tag" ]] || is_newer_release_tag "$candidate_tag" "$latest_tag"; then
        latest_tag="$candidate_tag"
      fi
    fi
  done < "$published_tags"
  rm -f -- "$published_tags"

  [[ -n "$latest_tag" ]] || fail 'no stable published release tag is reachable from main'
  printf '%s\n' "$latest_tag"
}

main_commit=$(resolve_remote_main_commit)
is_ancestor_of_main "$expected_commit" "$main_commit" || fail "release source $expected_commit is not reachable from remote main"
latest_release_tag=$(latest_published_stable_release_tag "$main_commit")
[[ "$release_tag" == "$latest_release_tag" ]] || fail "$release_tag is not the latest published stable release tag ($latest_release_tag)"

# Re-resolve both the source and latest published release after the first pass.
# These must remain identical at the final point before a caller crosses a
# release boundary. A protected tag policy prevents retagging after this check.
[[ "$(resolve_remote_tag_commit "$release_tag")" == "$expected_commit" ]] || fail "remote tag $release_tag changed during validation"
final_main_commit=$(resolve_remote_main_commit)
is_ancestor_of_main "$expected_commit" "$final_main_commit" || fail "release source $expected_commit is no longer reachable from remote main"
final_latest_release_tag=$(latest_published_stable_release_tag "$final_main_commit")
[[ "$release_tag" == "$final_latest_release_tag" ]] || fail "$release_tag is no longer the latest published stable release tag ($final_latest_release_tag)"

printf 'Verified protected current stable TestFlight tag %s at %s\n' "$release_tag" "$expected_commit"
