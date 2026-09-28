#!/bin/sh
# Proves the CBIO GS1 vendor-material rule rejects material and clears the tree.
#
# Two assertions, both required:
#   1. the checked-out tree carries no vendor material; and
#   2. a deliberate synthetic canary is reported by the same rule.
#
# The second exists so that a rule which silently stops matching fails this
# check instead of reporting a clean tree. No vendor byte, key-derived vector,
# or device address is stored in this script or in the rule it runs.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
config="$repo_root/security/gitleaks-vendor-material.toml"
rule_id=cbio-vendor-material-constant

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ -f "$config" ] || die "missing guard config $config"

gitleaks_bin=${GITLEAKS_BIN:-}
if [ -z "$gitleaks_bin" ]; then
  for candidate in \
    "$repo_root/.dart_tool/quality-tools/bin/gitleaks" \
    "$(command -v gitleaks 2>/dev/null || true)"
  do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      gitleaks_bin=$candidate
      break
    fi
  done
fi
[ -n "$gitleaks_bin" ] ||
  die 'gitleaks is required; run make tooling-bootstrap or set GITLEAKS_BIN'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-vendor-guard.XXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Exit codes: 0 clean, 2 findings, anything else is a scanner failure.
scan() {
  "$gitleaks_bin" detect \
    --no-git \
    --source "$1" \
    --config "$config" \
    --redact \
    --exit-code=2 \
    --report-format json \
    --report-path "$2" \
    >/dev/null 2>&1
}

tree_report="$work_dir/tree.json"
tree_status=0
scan "$repo_root" "$tree_report" || tree_status=$?
case "$tree_status" in
  0) ;;
  2)
    die "the tree compiles vendor material ($(grep -c '"RuleID"' "$tree_report") finding(s))"
    ;;
  *) die "gitleaks could not scan the tree (exit $tree_status)" ;;
esac

canary_root="$work_dir/canary"
canary_file="$canary_root/packages/cgm_cbio/lib/src/vendor_material_canary.dart"
mkdir -p "$(dirname -- "$canary_file")"
# The binding name and the payload are assembled here rather than written as one
# literal, so this script does not itself carry a material-shaped constant for
# the rule, or any other scanner, to match.
canary_binding=cbioVendorStreamKey
canary_payload='<int>[0x00, 0x01, 0x02, 0x03]'
{
  printf '// Synthetic canary: not the vendor material, same binding shape.\n'
  printf 'const List<int> %s = %s;\n' "$canary_binding" "$canary_payload"
} >"$canary_file"

canary_report="$work_dir/canary.json"
canary_status=0
scan "$canary_root" "$canary_report" || canary_status=$?
[ "$canary_status" = 2 ] ||
  die "the guard did not report its own canary (exit $canary_status); the rule is not working"
grep -q "$rule_id" "$canary_report" ||
  die "the canary was reported by a rule other than $rule_id"

printf 'vendor-material guard: %s rejected the canary and the tree is clean.\n' "$rule_id"
