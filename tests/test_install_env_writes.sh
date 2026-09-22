#!/usr/bin/env bash
#
# tests/test_install_env_writes.sh — targeted tests for how install.sh
# writes ENGRAM_DATA_DIR / ENGRAM_PORT into <instance>.env:
#
#   D1 — an instance kept from an existing router.json (non-interactive
#        re-run, or a menu choice that keeps instances) must have its
#        data_dir EXPANDED ($HOME/~ tokens) before it lands in the env
#        file. EnvironmentFile= is read by systemd verbatim — it does not
#        expand $HOME or ~ — and it overrides the unit template's
#        Environment= fallback, so an unexpanded token silently breaks the
#        daemon's data directory.
#   D2 — the env-file writer must never lose existing content. A data_dir
#        containing a byte that used to be a sed delimiter must not leave
#        the file empty.
#   D3 — the env-file writer must never let '&' or a trailing '\' in the
#        value be reinterpreted; every byte must round-trip verbatim.
#
# tests/test_install_port.sh already covers port assignment end-to-end
# with an always-already-expanded default data dir (no $HOME/~ token, no
# odd bytes); this file targets the cases that only show up when a
# data_dir comes back out of an existing router.json or contains bytes a
# sed-based writer could not survive.
#
# Test-safety (non-negotiable on this machine, same rules as
# tests/test_install_port.sh):
#   - every install.sh run/source uses a fixture $HOME, never the real one
#   - every full install.sh run is wrapped in `timeout` with ENGRAM_CLOUD_*
#     scrubbed
#   - the real $HOME's engram-router files are snapshotted before/after
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
assert_match() {  # label substring text
    if [[ "$3" == *"$2"* ]]; then _pass "$1"
    else _fail "$1" "'$2' not found in: $3"; fi
}

# ---------------------------------------------------------------------------
# Real $HOME safety net — see tests/test_install_port.sh for the rationale.
# Every install.sh invocation below (both full runs and `source`) is pinned
# to a fixture $HOME via the HOME env var before install.sh ever runs, so
# none of them can reach the real ~/.config/engram-router.
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -name 'engram@.service' 2>/dev/null
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

FIXTURE_BASE="$(mktemp -d)"
trap 'chmod -R u+rwx "$FIXTURE_BASE" 2>/dev/null; rm -rf "$FIXTURE_BASE"' EXIT

new_fixture_home() {  # subdir name -> prints the fixture $HOME path
    local d="$FIXTURE_BASE/$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

env_file_for() {  # fixture_home instance_name -> prints the .env path
    printf '%s/.config/engram-router/instances/%s.env' "$1" "$2"
}

# Runs install.sh non-interactively (full process, not sourced) against a
# fixture $HOME, with ENGRAM_CLOUD_* scrubbed and under a timeout — same
# helper as tests/test_install_port.sh.
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

# Sources install.sh with a fixture $HOME and calls one of its internal
# env-writing functions directly, in a subshell so nothing leaks back into
# this harness. install.sh's own BASH_SOURCE guard keeps main() from
# running under `source`, so this never prompts, never touches systemd,
# and never provisions credentials — it only reaches the one named
# function. This is deliberately never done against the real $HOME.
call_env_fn() {
    local fixture_home="$1" fn="$2"; shift 2
    (
        export HOME="$fixture_home"
        export ENGRAM_ROUTER_BIN="$fixture_home/.local/bin"
        export ENGRAM_ROUTER_LIB_DIR="$fixture_home/.local/lib/engram-router"
        export ENGRAM_ROUTER_CONFIG_DIR="$fixture_home/.config/engram-router"
        # shellcheck source=../install.sh
        # shellcheck disable=SC1091
        source "$ROOT_DIR/install.sh"
        "$fn" "$@"
    )
}

# ===========================================================================
# D1 — expansion for an instance kept from an existing router.json
# ===========================================================================

echo "== D1: a kept instance whose router.json data_dir is the literal \"\$HOME/...\" token gets it EXPANDED in its .env =="
home_a="$(new_fixture_home home_a)"
mkdir -p "$home_a/.config/engram-router"
cat > "$home_a/.config/engram-router/router.json" <<'JSON'
{
  "rules": [
  ],
  "instances": {
    "work": { "data_dir": "$HOME/.local/share/engram-work", "port": 7437 }
  }
}
JSON
run_install "$home_a" </dev/null >/dev/null 2>&1
env_a="$(env_file_for "$home_a" work)"
if [[ -r "$env_a" ]]; then
    assert_eq "D1a: ENGRAM_DATA_DIR is the expanded absolute path, no literal \$HOME" \
        "ENGRAM_DATA_DIR=$home_a/.local/share/engram-work" \
        "$(grep '^ENGRAM_DATA_DIR=' "$env_a" 2>/dev/null)"
else
    _fail "D1a: work.env exists after install" "$env_a not found"
fi

echo
echo "== D1: same, with the literal \"~/...\" token =="
home_b="$(new_fixture_home home_b)"
mkdir -p "$home_b/.config/engram-router"
cat > "$home_b/.config/engram-router/router.json" <<'JSON'
{
  "rules": [
  ],
  "instances": {
    "work": { "data_dir": "~/.engram", "port": 7437 }
  }
}
JSON
run_install "$home_b" </dev/null >/dev/null 2>&1
env_b="$(env_file_for "$home_b" work)"
if [[ -r "$env_b" ]]; then
    assert_eq "D1b: ENGRAM_DATA_DIR is the expanded absolute path, no literal ~" \
        "ENGRAM_DATA_DIR=$home_b/.engram" \
        "$(grep '^ENGRAM_DATA_DIR=' "$env_b" 2>/dev/null)"
else
    _fail "D1b: work.env exists after install" "$env_b not found"
fi

# ===========================================================================
# D2 — a '|' data_dir must not destroy the env file
# ===========================================================================

echo
echo "== D2: a data_dir containing '|' does not empty the env file (previously: sed delimiter collision -> 0 bytes, exit 0) =="
home_c="$(new_fixture_home home_c)"
env_c="$(env_file_for "$home_c" work)"
mkdir -p "$(dirname "$env_c")"
printf 'ENGRAM_PORT=9999\n# autosync note\nENGRAM_CLOUD_AUTOSYNC=true\n' > "$env_c"
pipe_dir="$home_c/data|dir"
if call_env_fn "$home_c" write_instance_data_dir_env work "$pipe_dir" 2>/dev/null; then
    _pass "D2: write_instance_data_dir_env succeeds for a data_dir containing '|'"
else
    _fail "D2: write_instance_data_dir_env succeeds for a data_dir containing '|'" "function returned non-zero"
fi
if [[ -s "$env_c" ]]; then
    _pass "D2: env file is not left at 0 bytes after a '|' data_dir"
else
    _fail "D2: env file is not left at 0 bytes after a '|' data_dir" "file is empty or missing"
fi
assert_eq "D2: ENGRAM_DATA_DIR line preserves the literal '|'" \
    "ENGRAM_DATA_DIR=$pipe_dir" "$(grep '^ENGRAM_DATA_DIR=' "$env_c" 2>/dev/null)"
assert_eq "D2: pre-existing ENGRAM_PORT line survives untouched" \
    "ENGRAM_PORT=9999" "$(grep '^ENGRAM_PORT=' "$env_c" 2>/dev/null)"
assert_eq "D2: pre-existing autosync comment survives untouched" \
    "1" "$(grep -c '^# autosync note$' "$env_c" 2>/dev/null)"
assert_eq "D2: pre-existing ENGRAM_CLOUD_AUTOSYNC line survives untouched" \
    "ENGRAM_CLOUD_AUTOSYNC=true" "$(grep '^ENGRAM_CLOUD_AUTOSYNC=' "$env_c" 2>/dev/null)"

# ===========================================================================
# D3 — '&', trailing '\', spaces and quotes must round-trip verbatim
# ===========================================================================

echo
echo "== D3: '&', a trailing backslash, a space and a single quote in a data_dir are written and read back verbatim =="
home_d="$(new_fixture_home home_d)"
weird_names=(amp backslash space quote)
weird_dirs=(
    "$home_d/weird&dir"
    "$home_d/weird\\"
    "$home_d/weird dir"
    "$home_d/weird'dir"
)
for idx in "${!weird_dirs[@]}"; do
    inst="w-${weird_names[$idx]}"
    wd="${weird_dirs[$idx]}"
    call_env_fn "$home_d" write_instance_data_dir_env "$inst" "$wd" 2>/dev/null
    env_w="$(env_file_for "$home_d" "$inst")"
    assert_eq "D3 (${weird_names[$idx]}): ENGRAM_DATA_DIR round-trips byte-for-byte" \
        "ENGRAM_DATA_DIR=$wd" "$(cat "$env_w" 2>/dev/null)"
done

# ===========================================================================
# Replace-not-duplicate, ordering preserved
# ===========================================================================

echo
echo "== an env file with a pre-existing hand-written ENGRAM_DATA_DIR= line gets exactly one, updated in place =="
home_e="$(new_fixture_home home_e)"
env_e="$(env_file_for "$home_e" work)"
mkdir -p "$(dirname "$env_e")"
printf 'ENGRAM_PORT=7000\nENGRAM_DATA_DIR=/old/hand-written/path\n# autosync comment\nENGRAM_CLOUD_AUTOSYNC=true\n' > "$env_e"
new_dir="$home_e/.local/share/engram-work"
call_env_fn "$home_e" write_instance_data_dir_env work "$new_dir" 2>/dev/null
assert_eq "replace: exactly one ENGRAM_DATA_DIR= line after update" \
    "1" "$(grep -c '^ENGRAM_DATA_DIR=' "$env_e" 2>/dev/null)"
expected_order=$'ENGRAM_PORT=7000\nENGRAM_DATA_DIR='"$new_dir"$'\n# autosync comment\nENGRAM_CLOUD_AUTOSYNC=true'
assert_eq "replace: ENGRAM_PORT / comment / ENGRAM_CLOUD_AUTOSYNC survive in original order, DATA_DIR updated in place" \
    "$expected_order" "$(cat "$env_e" 2>/dev/null)"

# ===========================================================================
# No trailing newline stays well-formed
# ===========================================================================

echo
echo "== an env file with no trailing newline stays well-formed after a write =="
home_f="$(new_fixture_home home_f)"
env_f="$(env_file_for "$home_f" work)"
mkdir -p "$(dirname "$env_f")"
printf 'ENGRAM_PORT=1234' > "$env_f"   # deliberately no trailing newline
call_env_fn "$home_f" write_instance_data_dir_env work "$home_f/data" 2>/dev/null
assert_eq "no-trailing-newline: pre-existing line is preserved intact" \
    "1" "$(grep -c '^ENGRAM_PORT=1234$' "$env_f" 2>/dev/null)"
assert_eq "no-trailing-newline: ENGRAM_DATA_DIR line was appended correctly" \
    "ENGRAM_DATA_DIR=$home_f/data" "$(grep '^ENGRAM_DATA_DIR=' "$env_f" 2>/dev/null)"
last_byte="$(tail -c1 "$env_f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
assert_eq "no-trailing-newline: output file itself ends with a trailing newline" "0a" "$last_byte"

# ===========================================================================
# Idempotence
# ===========================================================================

echo
echo "== running the same write twice is idempotent =="
home_g="$(new_fixture_home home_g)"
env_g="$(env_file_for "$home_g" work)"
call_env_fn "$home_g" write_instance_data_dir_env work "$home_g/data" 2>/dev/null
first="$(cat "$env_g" 2>/dev/null)"
call_env_fn "$home_g" write_instance_data_dir_env work "$home_g/data" 2>/dev/null
second="$(cat "$env_g" 2>/dev/null)"
assert_eq "idempotence: file content is unchanged across a second identical run" "$first" "$second"
assert_eq "idempotence: still exactly one ENGRAM_DATA_DIR= line after two runs" \
    "1" "$(grep -c '^ENGRAM_DATA_DIR=' "$env_g" 2>/dev/null)"

# ===========================================================================
# write_instance_port_env shares the same safe replace-or-append logic
# ===========================================================================

echo
echo "== write_instance_port_env uses the same sed-free replace-or-append logic (no divergent implementation) =="
home_h="$(new_fixture_home home_h)"
env_h="$(env_file_for "$home_h" work)"
mkdir -p "$(dirname "$env_h")"
printf 'ENGRAM_DATA_DIR=%s\nENGRAM_PORT=1111\n' "$home_h/data" > "$env_h"
call_env_fn "$home_h" write_instance_port_env work 2222 2>/dev/null
assert_eq "port: exactly one ENGRAM_PORT= line after update" \
    "1" "$(grep -c '^ENGRAM_PORT=' "$env_h" 2>/dev/null)"
assert_eq "port: ENGRAM_DATA_DIR / ENGRAM_PORT survive in original order, PORT updated in place" \
    "ENGRAM_DATA_DIR=$home_h/data"$'\n'"ENGRAM_PORT=2222" "$(cat "$env_h" 2>/dev/null)"

# ===========================================================================
# A failed write must never overwrite the env file (no mv over a failed tmp)
# ===========================================================================

echo
echo "== a write that cannot create its temp file leaves the env file byte-identical and reports failure =="
home_i="$(new_fixture_home home_i)"
env_i="$(env_file_for "$home_i" work)"
mkdir -p "$(dirname "$env_i")"
original_content=$'ENGRAM_DATA_DIR=/original/untouched\nENGRAM_PORT=5555'
printf '%s\n' "$original_content" > "$env_i"
instances_dir="$(dirname "$env_i")"
chmod 0555 "$instances_dir"
if call_env_fn "$home_i" write_instance_data_dir_env work "/new/path" 2>/dev/null; then
    _fail "failed-write: function reports failure when the temp file cannot be created" "returned success"
else
    _pass "failed-write: function reports failure when the temp file cannot be created"
fi
chmod 0755 "$instances_dir"
assert_eq "failed-write: env file is left byte-identical after a failed write" \
    "$original_content" "$(cat "$env_i" 2>/dev/null)"

# F1: a write that fails mid-stream must be observable (see _write_env_kv_body).
echo
echo "== F1: a write that fails mid-stream (ulimit -f) reports failure and leaves the env file untouched =="
home_j="$(new_fixture_home home_j)"
env_j="$(env_file_for "$home_j" work)"; mkdir -p "$(dirname "$env_j")"
orig_j=$'ENGRAM_PORT=6666\nENGRAM_CLOUD_AUTOSYNC=true'
printf '%s\n' "$orig_j" > "$env_j"
big_j="$(printf 'x%.0s' $(seq 1 4000))"
(
    export HOME="$home_j" ENGRAM_ROUTER_BIN="$home_j/.local/bin" \
        ENGRAM_ROUTER_LIB_DIR="$home_j/.local/lib/engram-router" \
        ENGRAM_ROUTER_CONFIG_DIR="$home_j/.config/engram-router"
    source "$ROOT_DIR/install.sh"
    trap '' XFSZ; ulimit -c 0; ulimit -f 1   # graceful EFBIG, not a SIGXFSZ kill
    write_instance_data_dir_env work "$big_j"
)
[[ $? -ne 0 ]] && _pass "F1: write reports failure on a mid-stream write error" \
    || _fail "F1: write reports failure on a mid-stream write error" "rc=0"
assert_eq "F1: env file left byte-identical after the failed write" "$orig_j" "$(cat "$env_j" 2>/dev/null)"

# F2: main()'s final loop must verify router_expand_path is actually defined,
# not trust source's own exit status (see _load_router_expand_path).
echo
echo "== F2: router.sh present -> succeeds; absent in both locations -> fails closed, no crash =="
home_k="$(new_fixture_home home_k)"
call_env_fn "$home_k" _load_router_expand_path 2>/dev/null \
    && _pass "F2: library present, router_expand_path becomes available" \
    || _fail "F2: library present, router_expand_path becomes available" "reported unavailable"
home_l="$(new_fixture_home home_l)"
cp "$ROOT_DIR/install.sh" "$home_l/install.sh"
( export HOME="$home_l" ENGRAM_ROUTER_LIB_DIR="$home_l/nope" \
      ENGRAM_ROUTER_CONFIG_DIR="$home_l/.config/engram-router"
  source "$home_l/install.sh"; _load_router_expand_path ) 2>/dev/null \
    && _fail "F2: library absent, router_expand_path stays unavailable" "reported available" \
    || _pass "F2: library absent, router_expand_path stays unavailable"

# F3: an instance already serving real data at its effective dir must not be
# silently repointed (see _instance_effective_data_dir).
_f3_router_json() { cat > "$1/.config/engram-router/router.json" <<JSON
{"rules": [], "instances": {"work": {"data_dir": "$2", "port": 7437}}}
JSON
}

echo
echo "== F3(a): old effective dir has engram.db; router.json points elsewhere -> NOT rewritten, warning names both paths =="
home_m="$(new_fixture_home home_m)"
mkdir -p "$home_m/.config/engram-router" "$home_m/.local/share/engram-work"
: > "$home_m/.local/share/engram-work/engram.db"
target_m="$home_m/.other/place"
_f3_router_json "$home_m" "$target_m"
out_m="$(run_install "$home_m" </dev/null 2>&1)"
assert_eq "F3a: ENGRAM_DATA_DIR is NOT rewritten" \
    "" "$(grep '^ENGRAM_DATA_DIR=' "$(env_file_for "$home_m" work)" 2>/dev/null)"
assert_match "F3a: warning names the old path" "$home_m/.local/share/engram-work" "$out_m"
assert_match "F3a: warning names the new path" "$target_m" "$out_m"

echo
echo "== F3(b): old effective dir has NO engram.db -> rewritten normally, no warning =="
home_n="$(new_fixture_home home_n)"
mkdir -p "$home_n/.config/engram-router"
target_n="$home_n/.other/place"
_f3_router_json "$home_n" "$target_n"
out_n="$(run_install "$home_n" </dev/null 2>&1)"
assert_eq "F3b: ENGRAM_DATA_DIR IS rewritten" \
    "ENGRAM_DATA_DIR=$target_n" "$(grep '^ENGRAM_DATA_DIR=' "$(env_file_for "$home_n" work)" 2>/dev/null)"
assert_eq "F3b: no skip warning" "0" "$(grep -c 'sin tocar' <<<"$out_n")"

echo
echo "== F3(c): env already has the effective value -> unchanged, no warning =="
home_o="$(new_fixture_home home_o)"
same_dir="$home_o/.local/share/engram-work"
mkdir -p "$home_o/.config/engram-router/instances" "$same_dir"
: > "$same_dir/engram.db"
printf 'ENGRAM_DATA_DIR=%s\nENGRAM_PORT=7437\n' "$same_dir" > "$(env_file_for "$home_o" work)"
_f3_router_json "$home_o" "$same_dir"
out_o="$(run_install "$home_o" </dev/null 2>&1)"
assert_eq "F3c: ENGRAM_DATA_DIR unchanged" \
    "ENGRAM_DATA_DIR=$same_dir" "$(grep '^ENGRAM_DATA_DIR=' "$(env_file_for "$home_o" work)" 2>/dev/null)"
assert_eq "F3c: no skip warning" "0" "$(grep -c 'sin tocar' <<<"$out_o")"

# ===========================================================================
# G1 — _instance_effective_data_dir must not depend on an ambient global
# "name". A single `local a="$1" b="...$a..."` statement expands every RHS
# in the OUTER scope before any of that statement's names become local, so
# a "$a" reference inside the same statement never sees "$1" — it only
# happened to work here because the one call site in main()'s final loop
# always sets a GLOBAL "name" to the same value right before calling this
# function. Both branches below call the function directly (via a sourced,
# non-main()-running install.sh) with no such coincidence in play.
# ===========================================================================
echo
echo "== G1: _instance_effective_data_dir does not depend on a stale/absent global \"name\" =="
home_g="$(new_fixture_home home_g)"
mkdir -p "$home_g/.config/engram-router/instances"
printf 'ENGRAM_DATA_DIR=%s\nENGRAM_PORT=7437\n' "$home_g/custom/work-dir" > "$(env_file_for "$home_g" work)"
printf 'ENGRAM_DATA_DIR=%s\nENGRAM_PORT=7438\n' "$home_g/custom/other-dir" > "$(env_file_for "$home_g" other)"

echo "-- G1a: no matching global \"name\" is set at all (would crash under set -u if \$1 leaked) --"
out_g1a="$(call_env_fn "$home_g" _instance_effective_data_dir work 2>&1)"
rc_g1a=$?
assert_eq "G1a: exits 0 (no 'unbound variable' crash)" "0" "$rc_g1a"
assert_eq "G1a: returns work's own value with no ambient \$name" \
    "$home_g/custom/work-dir" "$out_g1a"

echo "-- G1b: a deliberately WRONG stale global \"name\" is set before the call --"
out_g1b="$(
    export HOME="$home_g"
    export ENGRAM_ROUTER_BIN="$home_g/.local/bin"
    export ENGRAM_ROUTER_LIB_DIR="$home_g/.local/lib/engram-router"
    export ENGRAM_ROUTER_CONFIG_DIR="$home_g/.config/engram-router"
    # shellcheck source=../install.sh
    # shellcheck disable=SC1091
    source "$ROOT_DIR/install.sh"
    name="other"
    _instance_effective_data_dir work
)"
assert_eq "G1b: still returns work's own value, ignoring the stale global \$name=other" \
    "$home_g/custom/work-dir" "$out_g1b"

echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's engram-router files are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
