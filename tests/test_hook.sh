#!/usr/bin/env bash
#
# tests/test_hook.sh — integration tests for `engram-router hook <bash|zsh>`,
# the shell integration that replaces the retired `bin/engram` PATH shim.
#
# Covers: syntax of the emitted code, per-directory ENGRAM_DATA_DIR routing
# (including the stale-value regression when moving from a matched to an
# unmatched directory), the cloud-op refusal policy of the emitted `engram`
# shell function (refused vs. passed through, via a stub `engram` binary),
# that the function never shadows the real binary on PATH, the $PWD cache
# (no repeat subprocess calls for an unchanged directory), and the
# `command -v engram-router` → self-path fallback used to locate the real
# tool at hook-eval time.
#
# Test-safety (same discipline as tests/test_install_port.sh):
#   - every eval of the emitted hook runs with HOME pointed at a fixture
#     directory, never the real one
#   - the real $HOME's engram-router files are snapshotted before and after
#     to prove they were not touched (the hook installs nothing itself)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PATH="$PATH"

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
assert_true() {  # label command...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then _pass "$label"
    else _fail "$label" "command failed: $*"; fi
}

# ---------------------------------------------------------------------------
# Real $HOME safety net (same pattern as tests/test_install_port.sh).
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
FIXTURE_HOME="$FIXTURE/home"
mkdir -p "$FIXTURE_HOME"

# ---------------------------------------------------------------------------
# Fixture router.json: two instances, "trabajo" (a work namespace) and
# "personal" (a personal one).
# ---------------------------------------------------------------------------
CONFIG_DIR="$FIXTURE_HOME/.config/engram-router"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/router.json"
TRABAJO_DATA_DIR="$FIXTURE_HOME/.local/share/engram-trabajo"
PERSONAL_DATA_DIR="$FIXTURE_HOME/.local/share/engram-personal"

cat >"$CONFIG_FILE" <<EOF
{
  "rules": [
    { "prefix": "github.com/mi-empresa", "instance": "trabajo" },
    { "prefix": "github.com/mi-usuario", "instance": "personal" }
  ],
  "instances": {
    "trabajo": { "data_dir": "$TRABAJO_DATA_DIR", "port": 7438, "autosync": true },
    "personal": { "data_dir": "$PERSONAL_DATA_DIR", "port": 7439, "autosync": true }
  }
}
EOF

# ---------------------------------------------------------------------------
# Fixture git repos with remotes.
# ---------------------------------------------------------------------------
WORK_REPO="$FIXTURE/work_repo"
git init -q "$WORK_REPO"
git -C "$WORK_REPO" remote add origin git@github.com:mi-empresa/proyecto.git

PERSONAL_REPO="$FIXTURE/personal_repo"
git init -q "$PERSONAL_REPO"
git -C "$PERSONAL_REPO" remote add origin git@github.com:mi-usuario/proyecto.git

UNMATCHED_REPO="$FIXTURE/unmatched_repo"
git init -q "$UNMATCHED_REPO"
git -C "$UNMATCHED_REPO" remote add origin git@github.com:otro-tercero/proyecto.git

# ---------------------------------------------------------------------------
# Stub `engram` binary: records every invocation's args (one per line) and
# echoes ENGRAM_DATA_DIR so tests can see what the hooked shell passed down.
# ---------------------------------------------------------------------------
STUB_DIR="$FIXTURE/stub_bin"
mkdir -p "$STUB_DIR"
STUB_LOG="$FIXTURE/stub.log"
cat >"$STUB_DIR/engram" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ENGRAM_STUB_LOG"
printf 'ENGRAM_DATA_DIR=%s\n' "${ENGRAM_DATA_DIR:-}"
EOF
chmod +x "$STUB_DIR/engram"

# ---------------------------------------------------------------------------
# Counting wrapper for `engram-router` itself, used by the cache test: it
# increments a byte-per-call counter file, then execs the real binary.
# ---------------------------------------------------------------------------
COUNT_DIR="$FIXTURE/count_bin"
mkdir -p "$COUNT_DIR"
COUNTER_FILE="$FIXTURE/router_calls.count"
: > "$COUNTER_FILE"
cat >"$COUNT_DIR/engram-router" <<EOF
#!/usr/bin/env bash
printf 'x' >> '$COUNTER_FILE'
exec '$ROOT_DIR/bin/engram-router' "\$@"
EOF
chmod +x "$COUNT_DIR/engram-router"

# ---------------------------------------------------------------------------
# Driver runner: executes a driver script under a fixture HOME/config/PATH,
# leaving DRV_OUT / DRV_ERR (file paths) / DRV_RC for the caller to inspect.
# ---------------------------------------------------------------------------
_run_driver() {  # driver_path path_override
    local driver="$1" path="$2"
    DRV_OUT="$(mktemp -p "$FIXTURE")"
    DRV_ERR="$(mktemp -p "$FIXTURE")"
    (
        export HOME="$FIXTURE_HOME"
        export ENGRAM_ROUTER_CONFIG="$CONFIG_FILE"
        export ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh"
        export ENGRAM_STUB_LOG="$STUB_LOG"
        export PATH="$path"
        bash "$driver"
    ) >"$DRV_OUT" 2>"$DRV_ERR"
    DRV_RC=$?
}

NORMAL_PATH="$STUB_DIR:$ROOT_DIR/bin:$REAL_PATH"

echo "== engram-router hook <shell>: generation and syntax =="

HOOK_BASH="$FIXTURE/hook.bash.sh"
hook_bash_rc=0
"$ROOT_DIR/bin/engram-router" hook bash >"$HOOK_BASH" 2>"$FIXTURE/hook_bash.err" || hook_bash_rc=$?
assert_eq "'hook bash' exits 0" "0" "$hook_bash_rc"
assert_true "'hook bash' output passes bash -n" bash -n "$HOOK_BASH"

HOOK_ZSH="$FIXTURE/hook.zsh.sh"
hook_zsh_rc=0
"$ROOT_DIR/bin/engram-router" hook zsh >"$HOOK_ZSH" 2>"$FIXTURE/hook_zsh.err" || hook_zsh_rc=$?
assert_eq "'hook zsh' exits 0" "0" "$hook_zsh_rc"
if command -v zsh >/dev/null 2>&1; then
    assert_true "'hook zsh' output passes zsh -n" zsh -n "$HOOK_ZSH"
else
    printf '  ok      %s (zsh not installed on this host; syntax check skipped)\n' "'hook zsh' output syntax check"
    PASS=$((PASS+1))
fi

"$ROOT_DIR/bin/engram-router" hook >/dev/null 2>/dev/null
assert_eq "'hook' with no shell argument exits 2" "2" "$?"
"$ROOT_DIR/bin/engram-router" hook fish >/dev/null 2>/dev/null
assert_eq "'hook fish' (unknown shell) exits 2" "2" "$?"

echo
echo "== per-directory ENGRAM_DATA_DIR routing (bash) =="

DRIVER_WORK="$FIXTURE/driver_work.sh"
cat >"$DRIVER_WORK" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$WORK_REPO' || exit 90
_engram_router_hook
printf 'DATA_DIR=%s\n' "\${ENGRAM_DATA_DIR:-}"
EOF
_run_driver "$DRIVER_WORK" "$NORMAL_PATH"
data_dir="$(sed -n 's/^DATA_DIR=//p' "$DRV_OUT")"
assert_eq "cd into the work repo exports the 'trabajo' instance's data dir" "$TRABAJO_DATA_DIR" "$data_dir"

DRIVER_PERSONAL="$FIXTURE/driver_personal.sh"
cat >"$DRIVER_PERSONAL" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$PERSONAL_REPO' || exit 90
_engram_router_hook
printf 'DATA_DIR=%s\n' "\${ENGRAM_DATA_DIR:-}"
EOF
_run_driver "$DRIVER_PERSONAL" "$NORMAL_PATH"
data_dir="$(sed -n 's/^DATA_DIR=//p' "$DRV_OUT")"
assert_eq "cd into the personal repo exports the 'personal' instance's data dir" "$PERSONAL_DATA_DIR" "$data_dir"

echo
echo "== unmatched directory: ENGRAM_DATA_DIR stays/becomes unset =="

DRIVER_FRESH_UNMATCHED="$FIXTURE/driver_fresh_unmatched.sh"
cat >"$DRIVER_FRESH_UNMATCHED" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$UNMATCHED_REPO' || exit 90
_engram_router_hook
if [[ -n "\${ENGRAM_DATA_DIR+set}" ]]; then printf 'SET\n'; else printf 'UNSET\n'; fi
EOF
_run_driver "$DRIVER_FRESH_UNMATCHED" "$NORMAL_PATH"
assert_eq "cd straight into an unmatched dir leaves ENGRAM_DATA_DIR unset" "UNSET" "$(cat "$DRV_OUT")"

DRIVER_STALE="$FIXTURE/driver_stale.sh"
cat >"$DRIVER_STALE" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$WORK_REPO' || exit 90
_engram_router_hook
cd '$UNMATCHED_REPO' || exit 90
_engram_router_hook
if [[ -n "\${ENGRAM_DATA_DIR+set}" ]]; then printf 'SET\n'; else printf 'UNSET\n'; fi
EOF
_run_driver "$DRIVER_STALE" "$NORMAL_PATH"
assert_eq "moving from a matched dir to an unmatched one unsets the stale ENGRAM_DATA_DIR" "UNSET" "$(cat "$DRV_OUT")"

echo
echo "== engram() function: refusal vs. pass-through, via the stub binary =="

DRIVER_REFUSE="$FIXTURE/driver_refuse.sh"
cat >"$DRIVER_REFUSE" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$UNMATCHED_REPO' || exit 90
_engram_router_hook
engram sync --cloud --project x
printf 'RC=%s\n' "\$?"
EOF
: > "$STUB_LOG"
_run_driver "$DRIVER_REFUSE" "$NORMAL_PATH"
assert_match "unresolved dir: 'engram sync' returns 1" '^RC=1$' "$(cat "$DRV_OUT")"
assert_match "unresolved dir: refusal message is printed on stderr" 'operación de nube rechazada' "$(cat "$DRV_ERR")"
if [[ -s "$STUB_LOG" ]]; then
    _fail "unresolved dir: stub engram was NOT invoked for a refused cloud op" "stub log: $(cat "$STUB_LOG")"
else
    _pass "unresolved dir: stub engram was NOT invoked for a refused cloud op"
fi

DRIVER_PASSTHROUGH="$FIXTURE/driver_passthrough.sh"
cat >"$DRIVER_PASSTHROUGH" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$UNMATCHED_REPO' || exit 90
_engram_router_hook
engram search foo
printf 'RC=%s\n' "\$?"
EOF
: > "$STUB_LOG"
_run_driver "$DRIVER_PASSTHROUGH" "$NORMAL_PATH"
assert_match "unresolved dir: local op 'engram search foo' passes through (RC=0)" '^RC=0$' "$(cat "$DRV_OUT")"
assert_eq "unresolved dir: stub received the exact args 'search foo'" "search foo" "$(cat "$STUB_LOG")"

DRIVER_MATCHED_SYNC="$FIXTURE/driver_matched_sync.sh"
cat >"$DRIVER_MATCHED_SYNC" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$WORK_REPO' || exit 90
_engram_router_hook
engram sync
printf 'RC=%s\n' "\$?"
EOF
: > "$STUB_LOG"
_run_driver "$DRIVER_MATCHED_SYNC" "$NORMAL_PATH"
assert_match "matched dir: 'engram sync' reaches the stub (RC=0)" '^RC=0$' "$(cat "$DRV_OUT")"
assert_eq "matched dir: stub received 'sync'" "sync" "$(cat "$STUB_LOG")"
seen_data_dir="$(sed -n 's/^ENGRAM_DATA_DIR=//p' "$DRV_OUT")"
assert_eq "matched dir: stub saw ENGRAM_DATA_DIR set to the trabajo instance's data dir" "$TRABAJO_DATA_DIR" "$seen_data_dir"

echo
echo "== the function never shadows the real binary on PATH =="

DRIVER_TYPEP="$FIXTURE/driver_typep.sh"
cat >"$DRIVER_TYPEP" <<EOF
eval "\$(cat '$HOOK_BASH')"
printf 'CHILD_CV=%s\n' "\$(bash -c 'command -v engram')"
EOF
_run_driver "$DRIVER_TYPEP" "$NORMAL_PATH"
child_cv="$(sed -n 's/^CHILD_CV=//p' "$DRV_OUT")"
# Note: this file used to also assert "type -P engram" resolves to the stub
# from the *same* shell that defines the engram() function. That assertion
# was vacuous: bash's `type -P` always bypasses shell functions, exported or
# not, so it would pass even if the function did shadow the binary. The
# child-shell 'command -v engram' check below is the discriminating one — it
# proves the function is invisible to other processes (never `export -f`'d).
assert_eq "a child shell's 'command -v engram' also resolves to the stub (function not exported)" "$STUB_DIR/engram" "$child_cv"

echo
echo "== \$PWD cache: no repeat engram-router invocation for an unchanged directory =="

DRIVER_CACHE="$FIXTURE/driver_cache.sh"
cat >"$DRIVER_CACHE" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$WORK_REPO' || exit 90
_engram_router_hook
printf 'C1=%s\n' "\$(wc -c < '$COUNTER_FILE')"
_engram_router_hook
printf 'C2=%s\n' "\$(wc -c < '$COUNTER_FILE')"
EOF
_run_driver "$DRIVER_CACHE" "$COUNT_DIR:$REAL_PATH"
c1="$(sed -n 's/^C1=[[:space:]]*//p' "$DRV_OUT")"
c2="$(sed -n 's/^C2=[[:space:]]*//p' "$DRV_OUT")"
assert_eq "a second hook call for the same \$PWD does not invoke engram-router again" "$c1" "$c2"

echo
echo "== self_path fallback: works even when engram-router is not on PATH =="

FOUND_ROUTER="$(PATH="$REAL_PATH" command -v engram-router 2>/dev/null || true)"
FALLBACK_PATH="$REAL_PATH"
if [[ -n "$FOUND_ROUTER" ]]; then
    found_dir="$(dirname "$FOUND_ROUTER")"
    FALLBACK_PATH="$(printf '%s' "$REAL_PATH" | tr ':' '\n' | grep -vF "$found_dir" | paste -sd: -)"
fi

DRIVER_FALLBACK="$FIXTURE/driver_fallback.sh"
cat >"$DRIVER_FALLBACK" <<EOF
eval "\$(cat '$HOOK_BASH')"
cd '$WORK_REPO' || exit 90
_engram_router_hook
printf 'DATA_DIR=%s\n' "\${ENGRAM_DATA_DIR:-}"
EOF
_run_driver "$DRIVER_FALLBACK" "$FALLBACK_PATH"
data_dir="$(sed -n 's/^DATA_DIR=//p' "$DRV_OUT")"
assert_eq "with engram-router absent from PATH, the embedded self-path fallback still resolves" "$TRABAJO_DATA_DIR" "$data_dir"

echo
echo "== zsh smoke test (functional, not just syntax) =="

if command -v zsh >/dev/null 2>&1; then
    DRIVER_ZSH="$FIXTURE/driver_zsh.zsh"
    cat >"$DRIVER_ZSH" <<EOF
eval "\$(cat '$HOOK_ZSH')"
cd '$PERSONAL_REPO' || exit 90
_engram_router_hook
printf 'DATA_DIR=%s\n' "\${ENGRAM_DATA_DIR:-}"
EOF
    ZSH_OUT="$(mktemp -p "$FIXTURE")"
    (
        export HOME="$FIXTURE_HOME"
        export ENGRAM_ROUTER_CONFIG="$CONFIG_FILE"
        export ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh"
        export PATH="$NORMAL_PATH"
        zsh "$DRIVER_ZSH"
    ) >"$ZSH_OUT" 2>&1
    data_dir="$(sed -n 's/^DATA_DIR=//p' "$ZSH_OUT")"
    assert_eq "zsh: cd into the personal repo exports the 'personal' instance's data dir" "$PERSONAL_DATA_DIR" "$data_dir"
else
    printf '  ok      %s (zsh not installed on this host; functional check skipped)\n' "zsh functional smoke test"
    PASS=$((PASS+1))
fi

echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's engram-router files are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
