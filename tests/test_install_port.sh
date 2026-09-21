#!/usr/bin/env bash
#
# tests/test_install_port.sh — integration tests for per-instance port
# assignment: install.sh (non-interactive), the router.json / <instance>.env
# it writes, bin/engram-migrate's sed still reading that router.json, and
# bin/engram-doctor's port-clash detection.
#
# tests/test_router.sh already covers the pure port-assignment logic
# (router_next_free_port / router_port_in_use) in isolation; this file
# covers the seam with install.sh, engram-migrate and engram-doctor.
#
# Test-safety (non-negotiable on this machine):
#   - every install.sh run uses a fixture $HOME, never the real one
#   - every install.sh run is wrapped in `timeout` and has ENGRAM_CLOUD_*
#     scrubbed from its environment
#   - nothing here ever binds 7437 or 7438; this machine's real
#     engram@trabajo.service / engram@personal.service are never touched
#   - the real $HOME's engram-router files are snapshotted before and after
#     to prove they were not touched
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
_pass() { printf '  ok      %s\n' "$1"; PASS=$((PASS+1)); }
_fail() {
    printf '  FAILED  %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '            %s\n' "$2"
    FAIL=$((FAIL+1))
}
assert_eq() {  # label expected actual
    if [[ "$2" == "$3" ]]; then _pass "$1"
    else _fail "$1" "expected '$2', got '$3'"; fi
}
assert_match() {  # label pattern text
    if grep -qE "$2" <<<"$3"; then _pass "$1"
    else _fail "$1" "does not match /$2/ — got: $3"; fi
}
assert_true() {  # label condition-description command...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then _pass "$label"
    else _fail "$label" "command failed: $*"; fi
}

# ---------------------------------------------------------------------------
# Real $HOME safety net: snapshot engram-router's real files before running
# anything, and diff again at the very end. Every install.sh call below runs
# against a fixture $HOME instead, never the real one.
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -name 'engram@.service' 2>/dev/null
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

# Runs install.sh non-interactively against a fixture $HOME, with
# ENGRAM_CLOUD_* scrubbed and under a timeout. stdin is /dev/null unless the
# caller redirected it, which is what makes install.sh take its
# non-interactive branch (single default/kept instance, no prompts).
run_install() {
    local fixture_home="$1"; shift
    (
        for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
        export HOME="$fixture_home"
        export ENGRAM_ROUTER_BIN="$fixture_home/.local/bin"
        export ENGRAM_ROUTER_LIB_DIR="$fixture_home/.local/lib/engram-router"
        export ENGRAM_ROUTER_CONFIG_DIR="$fixture_home/.config/engram-router"
        timeout 30 bash "$ROOT_DIR/install.sh" "$@"
    )
}

FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/home"
trap 'rm -rf "$FIXTURE"' EXIT

CONFIG_DIR="$FIXTURE/home/.config/engram-router"
CONFIG_FILE="$CONFIG_DIR/router.json"
ENV_DIR="$CONFIG_DIR/instances"

echo "== install.sh (non-interactive, fresh \$HOME): first run =="
run1_out="$(run_install "$FIXTURE/home" </dev/null 2>&1)"
if [[ -r "$CONFIG_FILE" ]]; then _pass "first run writes router.json"
else _fail "first run writes router.json" "$CONFIG_FILE not found"; fi
assert_match "install.sh announces the port it assigned to 'work'" \
    "Puerto asignado a 'work':" "$run1_out"

instance_line="$(grep -F '"work"' "$CONFIG_FILE" 2>/dev/null | head -1)"
port1="$(printf '%s' "$instance_line" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')"
if [[ -n "$port1" && "$port1" -ge 7437 ]]; then
    _pass "the default 'work' instance is assigned a port >= 7437 (got $port1)"
else
    _fail "the default 'work' instance is assigned a port >= 7437" "line was: $instance_line"
fi
if [[ "$port1" == "7437" || "$port1" == "7438" ]]; then
    printf '  note    got %s even though this host reports 7437/7438 in use — check the daemons\n' "$port1"
else
    printf '  note    got %s (this host'"'"'s real engram daemons occupy 7437/7438, correctly skipped)\n' "${port1:-?}"
fi

echo
echo "== router.json stays single-line per instance (engram-migrate cannot cross newlines) =="
assert_eq "the 'work' instance object is exactly one line" "1" \
    "$(grep -c '"work":[[:space:]]*{ "data_dir"' "$CONFIG_FILE")"

echo
echo "== bin/engram-migrate's own sed still extracts data_dir from the emitted line =="
extracted_dir="$(sed -n "s/.*\"work\"[[:space:]]*:[[:space:]]*{[^}]*\"data_dir\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" | head -1)"
assert_eq "engram-migrate's sed extracts the right data_dir" "$FIXTURE/home/.local/share/engram-work" "$extracted_dir"

echo
echo "== <instance>.env carries ENGRAM_PORT=<n> =="
env_file="$ENV_DIR/work.env"
if [[ -r "$env_file" ]]; then
    assert_match "work.env contains ENGRAM_PORT=$port1" "^ENGRAM_PORT=${port1}\$" "$(cat "$env_file")"
else
    _fail "work.env exists" "$env_file not found"
fi

echo
echo "== re-running install.sh keeps the existing port (stability across re-runs) =="
run2_out="$(run_install "$FIXTURE/home" </dev/null 2>&1)"
instance_line2="$(grep -F '"work"' "$CONFIG_FILE" 2>/dev/null | head -1)"
port2="$(printf '%s' "$instance_line2" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')"
assert_eq "the port is unchanged after a re-run" "$port1" "$port2"
assert_match "'se conserva la configuración existente' seen on the non-interactive re-run" \
    'conserva la configuración existente' "$run2_out"

echo
echo "== a deliberately-created port clash is reported by engram-doctor =="
# Hand-edit the fixture router.json to add a second instance sharing "work"'s
# port — this is the exact defect engram-doctor's new check exists to catch.
clash_dir="$FIXTURE/home/.local/share/engram-clash"
mkdir -p "$clash_dir"
tmp_config="$(mktemp)"
# No dependency beyond bash/coreutils (per README) — insert a sibling
# instance entry right after the "work" line, sharing the same port.
awk -v port="$port1" -v dir="$clash_dir" '
    { print }
    /"work":[[:space:]]*\{ "data_dir"/ && !done {
        print "    \"clash\": { \"data_dir\": \"" dir "\", \"port\": " port " }"
        done = 1
    }
' "$CONFIG_FILE" > "$tmp_config"
# The instances object has no trailing comma after "work" in a single-entry
# config, so one must be added before the newly inserted sibling line.
sed -i 's/\("work":[[:space:]]*{ "data_dir"[^}]*}\)$/\1,/' "$tmp_config"
mv "$tmp_config" "$CONFIG_FILE"

doctor_out="$(
    for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
    HOME="$FIXTURE/home" \
    ENGRAM_ROUTER_CONFIG="$CONFIG_FILE" \
    ENGRAM_ROUTER_BIN="$FIXTURE/home/.local/bin" \
    ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh" \
    timeout 30 bash "$ROOT_DIR/bin/engram-doctor" 2>&1
)"
assert_match "engram-doctor reports the shared port between 'work' and 'clash'" \
    "puerto $port1 asignado a más de una instancia" "$doctor_out"

echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's engram-router files are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
