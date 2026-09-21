#!/usr/bin/env bash
# tests/test_install_token_warning.sh — covers the token-survival warning
# added to install.sh's detect_hazardous_exports() preflight.
#
# The bug this guards against: the preflight's own remediation instructions
# tell the user to delete ENGRAM_CLOUD_* lines from their dotfiles. When
# those lines are the ONLY copy of ENGRAM_CLOUD_TOKEN, following that advice
# destroys the credential irrecoverably. This test asserts the preflight now
# warns BEFORE the numbered steps whenever that would happen, names the
# exact file:line locations, reports what it actually checked, and never
# prints the token value itself — and that it stays silent (no spurious
# warning) when a surviving copy exists or when the hazard is env-only with
# already-clean files.
#
# No framework: each check prints ok/FAIL and the script exits non-zero on
# any failure. Run with: bash tests/test_install_token_warning.sh
#
# Every install.sh invocation below runs against a disposable fixture HOME
# and with every real ENGRAM_CLOUD_* export scrubbed from its subshell
# environment first — the real machine this runs on has live ones, and a
# leaked one would silently make these assertions pass or fail for the
# wrong reason. install.sh is never given a chance to reach past its
# preflight: every scenario here is hazardous by construction, so it always
# exits 1 at detect_hazardous_exports, before install_files() or any
# interactive prompt.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$ROOT_DIR/install.sh"

PASS=0
FAIL=0

assert_match() {  # desc pattern text
    local desc="$1" pattern="$2" text="$3"
    if grep -qF "$pattern" <<<"$text"; then
        printf 'ok      %s\n' "$desc"
        ((PASS++))
    else
        printf 'FAIL    %s\n        missing: %s\n' "$desc" "$pattern"
        ((FAIL++))
    fi
}

assert_no_match() {  # desc pattern text
    local desc="$1" pattern="$2" text="$3"
    if grep -qF "$pattern" <<<"$text"; then
        printf 'FAIL    %s\n        unexpected: %s\n' "$desc" "$pattern"
        ((FAIL++))
    else
        printf 'ok      %s\n' "$desc"
        ((PASS++))
    fi
}

assert_eq() {  # desc expected actual
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok      %s\n' "$desc"
        ((PASS++))
    else
        printf 'FAIL    %s\n        expected: %q\n        actual:   %q\n' "$desc" "$expected" "$actual"
        ((FAIL++))
    fi
}

# Every real ENGRAM_CLOUD_* export on this machine, unset for the child
# process — see header comment. Built once; reused by every scenario.
_scrub_flags=()
while IFS= read -r v; do
    [[ -n "$v" ]] && _scrub_flags+=(-u "$v")
done < <(compgen -e | grep '^ENGRAM_CLOUD_' || true)

# run_install FIXTURE_HOME [EXTRA_ENGRAM_CLOUD_TOKEN_VALUE]
# Runs install.sh with HOME=FIXTURE_HOME and, if given, ENGRAM_CLOUD_TOKEN
# set to the second argument (simulating a sourced dotfile export). Sets
# OUT and STATUS. Never touches the real $HOME.
run_install() {
    local fixture_home="$1" token_env="${2:-}"
    local -a env_args=("${_scrub_flags[@]}" "HOME=$fixture_home")
    [[ -n "$token_env" ]] && env_args+=("ENGRAM_CLOUD_TOKEN=$token_env")
    OUT="$(env "${env_args[@]}" bash "$INSTALL_SH" </dev/null 2>&1)"
    STATUS=$?
}

# Snapshot of real-$HOME files this feature reads, taken before any
# scenario runs and compared again at the end — the concrete proof that no
# fixture ever leaked into the real $HOME.
_real_snapshot() {
    for p in "$HOME/.engram/cloud.json" "$HOME/.bashrc" "$HOME/.profile"; do
        if [[ -r "$p" ]]; then
            printf '%s:' "$p"
            sha256sum "$p" 2>/dev/null | cut -d' ' -f1
        else
            printf '%s:(absent)\n' "$p"
        fi
    done
}
BEFORE_REAL_HOME="$(_real_snapshot)"

# ---------------------------------------------------------------------------
# (a) Token only in dotfiles, no surviving copy anywhere -> prominent
#     warning, exact file:line locations, exit 1.
# ---------------------------------------------------------------------------
echo "== (a) token only in dotfiles, no surviving copy =="

FIXTURE_A="$(mktemp -d)"
mkdir -p "$FIXTURE_A/.engram"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": ""\n}\n' > "$FIXTURE_A/.engram/cloud.json"
{
    echo '# .bashrc'
    echo 'export ENGRAM_CLOUD_TOKEN=only-copy-abc'
} > "$FIXTURE_A/.bashrc"
{
    echo '# .profile'
    echo ''
    echo 'export ENGRAM_CLOUD_TOKEN=only-copy-abc'
} > "$FIXTURE_A/.profile"

run_install "$FIXTURE_A" "only-copy-abc"

assert_eq "(a) exits 1" "1" "$STATUS"
assert_match "(a) warns this is the only copy" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_match "(a) names .bashrc:2" "$FIXTURE_A/.bashrc:2" "$OUT"
assert_match "(a) names .profile:3" "$FIXTURE_A/.profile:3" "$OUT"
assert_match "(a) reports what was checked and found empty" "$FIXTURE_A/.engram/cloud.json (sin token)" "$OUT"
assert_match "(a) tells the user to save before step 1" "GUARDE el valor del token" "$OUT"
assert_match "(a) mentions issuing a new token as the fallback" "emitir un token nuevo" "$OUT"
assert_no_match "(a) never prints the token value" "only-copy-abc" "$OUT"
# The warning must appear before the numbered remediation steps, not after.
warn_pos="$(grep -bo 'ÚNICA COPIA DEL TOKEN' <<<"$OUT" | head -1 | cut -d: -f1)"
steps_pos="$(grep -bo 'Cómo resolverlo antes de reintentar' <<<"$OUT" | head -1 | cut -d: -f1)"
if [[ -n "$warn_pos" && -n "$steps_pos" && "$warn_pos" -lt "$steps_pos" ]]; then
    printf 'ok      %s\n' "(a) warning precedes the numbered steps"
    ((PASS++))
else
    printf 'FAIL    %s\n' "(a) warning precedes the numbered steps"
    ((FAIL++))
fi

rm -rf "$FIXTURE_A"

# ---------------------------------------------------------------------------
# (b) A non-empty token survives elsewhere -> no credential-loss warning,
#     a brief positive note instead. Two sub-cases: ~/.engram/cloud.json,
#     and an already-provisioned instance's cloud.json (via router.json).
# ---------------------------------------------------------------------------
echo "== (b) non-empty surviving copy -> no credential-loss warning =="

FIXTURE_B1="$(mktemp -d)"
mkdir -p "$FIXTURE_B1/.engram"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": "surviving-xyz"\n}\n' > "$FIXTURE_B1/.engram/cloud.json"
{
    echo '# .bashrc'
    echo 'export ENGRAM_CLOUD_TOKEN=surviving-xyz'
} > "$FIXTURE_B1/.bashrc"

run_install "$FIXTURE_B1" "surviving-xyz"

assert_eq "(b1) still exits 1 (hazard itself is unchanged)" "1" "$STATUS"
assert_no_match "(b1) no 'only copy' warning" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_match "(b1) positive note naming the surviving location" "$FIXTURE_B1/.engram/cloud.json" "$OUT"
assert_match "(b1) says it's safe to proceed" "Puede continuar con seguridad" "$OUT"
assert_no_match "(b1) never prints the token value" "surviving-xyz" "$OUT"

rm -rf "$FIXTURE_B1"

FIXTURE_B2="$(mktemp -d)"
mkdir -p "$FIXTURE_B2/.config/engram-router" "$FIXTURE_B2/.local/share/engram-work"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": "instance-token-99"\n}\n' \
    > "$FIXTURE_B2/.local/share/engram-work/cloud.json"
cat > "$FIXTURE_B2/.config/engram-router/router.json" <<'JSON'
{
  "rules": [
    { "prefix": "github.com/your-org", "instance": "work" }
  ],
  "instances": {
    "work": { "data_dir": "$HOME/.local/share/engram-work", "port": 7438, "autosync": true }
  }
}
JSON
{
    echo '# .bashrc'
    echo 'export ENGRAM_CLOUD_TOKEN=instance-token-99'
} > "$FIXTURE_B2/.bashrc"

run_install "$FIXTURE_B2" "instance-token-99"

assert_eq "(b2) still exits 1 (hazard itself is unchanged)" "1" "$STATUS"
assert_no_match "(b2) no 'only copy' warning" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_match "(b2) names the surviving instance's cloud.json" "engram-work/cloud.json" "$OUT"
assert_match "(b2) names the instance" "instancia work" "$OUT"
assert_no_match "(b2) never prints the token value" "instance-token-99" "$OUT"

rm -rf "$FIXTURE_B2"

# ---------------------------------------------------------------------------
# (c) Env-only hazard, files already clean -> unchanged branch: no
#     credential-loss warning (there are no lines to delete in the first
#     place), same remediation text as before this feature existed.
# ---------------------------------------------------------------------------
echo "== (c) env-only hazard, clean files -> existing branch preserved =="

FIXTURE_C="$(mktemp -d)"
# Deliberately no dotfiles, no ~/.engram at all.

run_install "$FIXTURE_C" "stale-session-token"

assert_eq "(c) exits 1" "1" "$STATUS"
assert_match "(c) uses the original env-only remediation text" "Los ficheros ya están limpios" "$OUT"
assert_no_match "(c) no credential-loss warning" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_no_match "(c) no surviving-copy note either" "se ha encontrado otra copia del token" "$OUT"
assert_no_match "(c) never prints the token value" "stale-session-token" "$OUT"

rm -rf "$FIXTURE_C"

# ---------------------------------------------------------------------------
# Real $HOME was never read or written by any of the above.
# ---------------------------------------------------------------------------
echo "== real \$HOME isolation =="

AFTER_REAL_HOME="$(_real_snapshot)"
assert_eq "real \$HOME files unchanged by the whole test run" "$BEFORE_REAL_HOME" "$AFTER_REAL_HOME"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
