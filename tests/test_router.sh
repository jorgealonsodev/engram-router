#!/usr/bin/env bash
# tests/test_router.sh — plain-bash unit tests for lib/router.sh.
# No framework: each check prints ok/FAIL and the script exits non-zero on
# any failure. Run with: bash tests/test_router.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/router.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/router.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok      %s\n' "$desc"
        ((PASS++))
    else
        printf 'FAIL    %s\n        expected: %q\n        actual:   %q\n' "$desc" "$expected" "$actual"
        ((FAIL++))
    fi
}

assert_status() {
    local desc="$1" expected_status="$2" actual_status="$3"
    if [[ "$expected_status" == "$actual_status" ]]; then
        printf 'ok      %s (exit %s)\n' "$desc" "$actual_status"
        ((PASS++))
    else
        printf 'FAIL    %s\n        expected exit: %s\n        actual exit:   %s\n' "$desc" "$expected_status" "$actual_status"
        ((FAIL++))
    fi
}

echo "== router_normalize_remote: the five audited remote forms =="

out="$(router_normalize_remote 'git@github.com:your-org/repo.git')"
assert_eq "SCP syntax (github.com/your-org)" "github.com/your-org" "$out"

out="$(router_normalize_remote 'https://github.com/your-org/repo.git')"
assert_eq "HTTPS URL syntax" "github.com/your-org" "$out"

out="$(router_normalize_remote 'ssh://git@gitlab.example.com:8443/your-user/repo.git')"
assert_eq "ssh:// with explicit port" "gitlab.example.com:8443/your-user" "$out"

out="$(router_normalize_remote 'gitlab.example.com:8443/your-user/repo.git')"
assert_eq "SCP syntax with non-standard port glued to path" "gitlab.example.com:8443/your-user" "$out"

out="$(router_normalize_remote 'git::@github.com/tmux-plugins/repo')"
assert_eq "git::@ plugin-manager prefix" "github.com/tmux-plugins" "$out"

echo "== router_normalize_remote: additional edge cases from the real audit =="

out="$(router_normalize_remote 'git@gitlab.com:your-user/repo.git')"
assert_eq "personal gitlab.com over SCP syntax" "gitlab.com/your-user" "$out"

out="$(router_normalize_remote 'https://gitlab.com/your-user/repo.git')"
assert_eq "personal gitlab.com over HTTPS" "gitlab.com/your-user" "$out"

out="$(router_normalize_remote 'ssh://git@github.com/your-org/repo.git')"
assert_eq "ssh:// without explicit port" "github.com/your-org" "$out"

out="$(router_normalize_remote 'git@github.com:your-org/repo')"
assert_eq "SCP syntax without .git suffix" "github.com/your-org" "$out"

router_normalize_remote '' >/dev/null 2>&1
assert_status "empty remote fails closed" "1" "$?"

router_normalize_remote 'not a remote at all' >/dev/null 2>&1
assert_status "garbage remote fails closed" "1" "$?"

echo "== router_load_config + router_match_instance =="

router_load_config "$ROOT_DIR/config/router.example.json"

out="$(router_match_instance 'github.com/your-org')"
assert_eq "example config routes your-org github to work" "work" "$out"

out="$(router_match_instance 'gitlab.example.com:8443/your-user')"
assert_eq "example config routes company gitlab (with port) to work" "work" "$out"

out="$(router_match_instance 'github.com/your-user')"
assert_eq "example config routes personal github to personal" "personal" "$out"

out="$(router_match_instance 'gitlab.com/your-user')"
assert_eq "example config routes personal gitlab.com to personal" "personal" "$out"

router_match_instance 'gitlab.com/some-other-org' >/dev/null 2>&1
assert_status "gitlab.com does NOT imply work for an unlisted owner" "1" "$?"

router_match_instance 'github.com/some-third-party' >/dev/null 2>&1
assert_status "unrelated github owner is unmatched" "1" "$?"

out="$(router_match_instance 'github.com/your-org-typo-owner')"
rc=$?
if [[ $rc -eq 0 && "$out" == "work" ]]; then
    printf 'FAIL    %s\n        boundary-unsafe prefix match: %q incorrectly matched\n' "prefix match is boundary-aware, not substring" "$out"
    ((FAIL++))
else
    printf 'ok      %s\n' "prefix match is boundary-aware, not substring"
    ((PASS++))
fi

echo "== router_expand_path =="

HOME_SAVED="$HOME"
HOME="/home/testuser"
# Intentionally literal: exercising router_expand_path's own substitution
# of the "$HOME" / "~" text, not shell expansion of this test script.
# shellcheck disable=SC2016,SC2088
out="$(router_expand_path '$HOME/.local/share/engram-work')"
assert_eq "expands literal \$HOME token" "/home/testuser/.local/share/engram-work" "$out"
# shellcheck disable=SC2088
out="$(router_expand_path '~/engram-personal')"
assert_eq "expands leading ~/" "/home/testuser/engram-personal" "$out"
HOME="$HOME_SAVED"

echo "== router_read_repo_override =="

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT
mkdir -p "$TMP_REPO/.engram"
cat >"$TMP_REPO/.engram/config.json" <<'EOF'
{
  "project_name": "example-project",
  "instance": "personal"
}
EOF
out="$(router_read_repo_override "$TMP_REPO")"
assert_eq "reads instance override alongside existing project_name" "personal" "$out"

TMP_REPO_NO_OVERRIDE="$(mktemp -d)"
mkdir -p "$TMP_REPO_NO_OVERRIDE/.engram"
cat >"$TMP_REPO_NO_OVERRIDE/.engram/config.json" <<'EOF'
{
  "project_name": "example-project"
}
EOF
router_read_repo_override "$TMP_REPO_NO_OVERRIDE" >/dev/null 2>&1
assert_status "no override key present fails closed" "1" "$?"
rm -rf "$TMP_REPO_NO_OVERRIDE"

echo "== router_resolve: end-to-end =="

TMP_REPO2="$(mktemp -d)"
git -C "$TMP_REPO2" init -q
git -C "$TMP_REPO2" remote add origin 'git@github.com:your-org/some-repo.git'
router_resolve "$TMP_REPO2" "$ROOT_DIR/config/router.example.json"
assert_eq "resolves instance via rule" "work" "$ROUTER_INSTANCE"
assert_eq "resolution source is 'rule'" "rule" "$ROUTER_SOURCE"
assert_eq "data dir resolved and \$HOME-expanded" "$HOME/.local/share/engram-work" "$ROUTER_DATA_DIR"
rm -rf "$TMP_REPO2"

TMP_REPO3="$(mktemp -d)"
git -C "$TMP_REPO3" init -q
git -C "$TMP_REPO3" remote add origin 'git@github.com:your-org/some-repo.git'
mkdir -p "$TMP_REPO3/.engram"
cat >"$TMP_REPO3/.engram/config.json" <<'EOF'
{ "project_name": "some-repo", "instance": "personal" }
EOF
router_resolve "$TMP_REPO3" "$ROOT_DIR/config/router.example.json"
assert_eq "repo-level override wins over rule match" "personal" "$ROUTER_INSTANCE"
assert_eq "resolution source is 'override'" "override" "$ROUTER_SOURCE"
rm -rf "$TMP_REPO3"

TMP_REPO4="$(mktemp -d)"
git -C "$TMP_REPO4" init -q
git -C "$TMP_REPO4" remote add origin 'git@github.com:some-third-party/repo.git'
router_resolve "$TMP_REPO4" "$ROOT_DIR/config/router.example.json"
assert_eq "unmatched remote resolves to no instance" "" "$ROUTER_INSTANCE"
assert_eq "resolution source is 'unmatched'" "unmatched" "$ROUTER_SOURCE"
rm -rf "$TMP_REPO4"

TMP_REPO5="$(mktemp -d)"
git -C "$TMP_REPO5" init -q
router_resolve "$TMP_REPO5" "$ROOT_DIR/config/router.example.json"
assert_eq "no remote at all resolves to no instance" "" "$ROUTER_INSTANCE"
assert_eq "resolution source is 'unmatched' with no remote" "unmatched" "$ROUTER_SOURCE"
rm -rf "$TMP_REPO5"

echo "== router_is_cloud_op =="

router_is_cloud_op sync
assert_status "'sync' is a cloud op" "0" "$?"
router_is_cloud_op cloud
assert_status "'cloud' is a cloud op" "0" "$?"
router_is_cloud_op search
assert_status "'search' is NOT a cloud op" "1" "$?"
router_is_cloud_op save
assert_status "'save' is NOT a cloud op" "1" "$?"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
