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
# It also covers the remediation commands built from that same preflight:
# both branches print copy-pasteable commands using the real files/variable
# names/PIDs actually detected (never a placeholder), the false claim that
# `systemctl --user unset-environment` can never remove an inherited
# variable is gone, every `sed -i.bak` suggestion is paired with the
# `chmod 600` its backup needs, and the daemon-restart step appears only
# when an "engram serve" process is actually running.
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
#
# `timeout` is load-bearing here too (see
# tests/test_install_existing_root_detection.sh): every hazardous scenario
# below is built to exit 1 at detect_hazardous_exports before any prompt,
# but a future regression that starts reading stdin instead would otherwise
# hang the whole suite rather than fail one check.
run_install() {
    local fixture_home="$1" token_env="${2:-}"
    local -a env_args=("${_scrub_flags[@]}" "HOME=$fixture_home")
    [[ -n "$token_env" ]] && env_args+=("ENGRAM_CLOUD_TOKEN=$token_env")
    OUT="$(timeout 20 env "${env_args[@]}" bash "$INSTALL_SH" </dev/null 2>&1)"
    STATUS=$?
}

# run_detect_hazardous_exports FIXTURE_HOME TOKEN_ENV STUB_PIDS
# Sources install.sh's function definitions (dropping its trailing
# `main "$@"`, same technique as
# tests/test_install_existing_root_detection.sh) in a fresh bash
# subprocess, overrides _engram_serve_pids to return STUB_PIDS (or nothing,
# simulating no daemon running, when STUB_PIDS is empty), then calls
# detect_hazardous_exports() directly. This is the only way to test the
# daemon-restart step deterministically: the real machine running this
# suite may or may not have an actual "engram serve" process up, and the
# step's presence must not depend on that machine's incidental state.
run_detect_hazardous_exports() {
    local fixture_home="$1" token_env="$2" stub_pids="$3"

    local harness
    harness="$(mktemp)"
    cat > "$harness" <<'HARNESS'
set -uo pipefail
# shellcheck source=/dev/null
source <(sed '$d' "$INSTALL_SH_PATH")
_engram_serve_pids() {
    [[ -n "$STUB_PIDS" ]] || return 1
    printf '%s\n' "$STUB_PIDS"
}
detect_hazardous_exports
HARNESS

    local -a env_args=("${_scrub_flags[@]}" "HOME=$fixture_home" \
        "INSTALL_SH_PATH=$INSTALL_SH" "STUB_PIDS=$stub_pids")
    [[ -n "$token_env" ]] && env_args+=("ENGRAM_CLOUD_TOKEN=$token_env")
    OUT="$(timeout 20 env "${env_args[@]}" bash "$harness" </dev/null 2>&1)"
    STATUS=$?
    rm -f "$harness"
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
# (b3) A cloud.json holding a DIFFERENT non-empty token is not a survivor.
#      Presence alone used to satisfy the check, so a rotated, revoked or
#      other-server token made the installer say "puede continuar con
#      seguridad" right before the user deleted the only copy of the live
#      credential. The warning has to stay fail-safe: reassure only on an
#      exact match.
# ---------------------------------------------------------------------------
echo "== (b3) a different stored token is NOT a survivor =="

FIXTURE_B3="$(mktemp -d)"
mkdir -p "$FIXTURE_B3/.engram"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": "stale-token-from-last-year"\n}\n' \
    > "$FIXTURE_B3/.engram/cloud.json"
{
    echo '# .bashrc'
    echo 'export ENGRAM_CLOUD_TOKEN=live-token-abc'
} > "$FIXTURE_B3/.bashrc"

run_install "$FIXTURE_B3" "live-token-abc"

assert_eq "(b3) still exits 1 (hazard itself is unchanged)" "1" "$STATUS"
assert_match "(b3) warns: a different token does not save the live one" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_no_match "(b3) does NOT reassure" "Puede continuar con seguridad" "$OUT"
assert_match "(b3) reports the mismatch as checked" "guarda otro token, no el activo" "$OUT"
assert_match "(b3) names the file it checked" "$FIXTURE_B3/.engram/cloud.json" "$OUT"
assert_no_match "(b3) never prints the live token value" "live-token-abc" "$OUT"
assert_no_match "(b3) never prints the stored token value" "stale-token-from-last-year" "$OUT"

rm -rf "$FIXTURE_B3"

# ---------------------------------------------------------------------------
# (c) Env-only hazard, files already clean -> no credential-loss warning
#     (there are no lines to delete in the first place); the env-only
#     branch keeps its own opening line, distinct from the files-present
#     branch's "Cómo resolverlo antes de reintentar".
# ---------------------------------------------------------------------------
echo "== (c) env-only hazard, clean files -> existing branch preserved =="

FIXTURE_C="$(mktemp -d)"
# Deliberately no dotfiles, no ~/.engram at all.

run_install "$FIXTURE_C" "stale-session-token"

assert_eq "(c) exits 1" "1" "$STATUS"
assert_match "(c) uses the env-only opening line" "Los ficheros ya están limpios" "$OUT"
assert_no_match "(c) no credential-loss warning" "ÚNICA COPIA DEL TOKEN" "$OUT"
assert_no_match "(c) no surviving-copy note either" "se ha encontrado otra copia del token" "$OUT"
assert_no_match "(c) never prints the token value" "stale-session-token" "$OUT"

rm -rf "$FIXTURE_C"

# ---------------------------------------------------------------------------
# (d) The false universal claim about systemd --user is gone from BOTH
#     remediation branches, and both print the real `systemctl --user
#     unset-environment` command built from what was actually detected —
#     never a placeholder.
# ---------------------------------------------------------------------------
echo "== (d) false unset-environment claim is gone; real command is printed =="

FALSE_CLAIM='no puede quitar esas'

# $OUT here is still scenario (c)'s env-only output (nothing has re-run
# install.sh since then): reused deliberately to check that branch too.
assert_no_match "(d/env-only) false unset-environment claim removed" "$FALSE_CLAIM" "$OUT"

FIXTURE_D="$(mktemp -d)"
mkdir -p "$FIXTURE_D/.engram"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": ""\n}\n' > "$FIXTURE_D/.engram/cloud.json"
{
    echo '# .bashrc'
    echo 'export ENGRAM_CLOUD_TOKEN=only-copy-def'
    echo 'export ENGRAM_CLOUD_SERVER=https://old.example'
} > "$FIXTURE_D/.bashrc"

run_install "$FIXTURE_D" "only-copy-def"

assert_eq "(d) exits 1" "1" "$STATUS"
assert_no_match "(d/files-present) false unset-environment claim removed" "$FALSE_CLAIM" "$OUT"
assert_match "(d) prints the real sed command against the detected file" \
    "sed -i.bak -E 's/^([[:space:]]*(export[[:space:]]+)?ENGRAM_CLOUD_)/# \\1/' $FIXTURE_D/.bashrc" "$OUT"
assert_match "(d) chmod 600 follows the sed backup it creates" "chmod 600 $FIXTURE_D/.bashrc.bak" "$OUT"
assert_match "(d) unset-environment names the real detected variables" \
    "systemctl --user unset-environment ENGRAM_CLOUD_SERVER ENGRAM_CLOUD_TOKEN" "$OUT"
assert_match "(d) explains reaching a clean shell" "Abra una shell" "$OUT"
assert_match "(d) gives the verification command" "env | grep ENGRAM_CLOUD" "$OUT"
assert_no_match "(d) never prints the token value" "only-copy-def" "$OUT"

# Every `sed -i.bak` COMMAND (not the prose sentence that also mentions it)
# is paired with its own `chmod 600` command right after: same count, or a
# backup was left unprotected. Anchored on the actual command lines'
# leading indent so the introductory prose line doesn't also count.
sed_count="$(grep -cE '^ {7}sed -i\.bak' <<<"$OUT")"
chmod_count="$(grep -cE '^ {7}chmod 600' <<<"$OUT")"
assert_eq "(d) one chmod 600 per sed -i.bak backup" "$sed_count" "$chmod_count"

rm -rf "$FIXTURE_D"

# ---------------------------------------------------------------------------
# (e) The daemon-restart step appears only when an "engram serve" process
#     is actually running. Driven through run_detect_hazardous_exports(),
#     which stubs _engram_serve_pids() directly: the real machine running
#     this suite may or may not have one up, and that must not decide the
#     outcome of this test.
# ---------------------------------------------------------------------------
echo "== (e) daemon-restart step is conditional on a real detected daemon =="

FIXTURE_E="$(mktemp -d)"
# Deliberately no dotfiles: env-only hazard, so the daemon step (if any) is
# the only optional step in the list, easy to isolate.

run_detect_hazardous_exports "$FIXTURE_E" "stale-session-token" "24601"
assert_eq "(e/present) exits 1" "1" "$STATUS"
assert_match "(e/present) prints the restart step with the stubbed PID" \
    "Reinicie el demonio Engram en marcha (PID 24601)" "$OUT"
assert_match "(e/present) explains what the restart is for" \
    "entorno contaminado" "$OUT"

run_detect_hazardous_exports "$FIXTURE_E" "stale-session-token" ""
assert_eq "(e/absent) exits 1" "1" "$STATUS"
assert_no_match "(e/absent) no restart step when no daemon is running" \
    "Reinicie el demonio Engram" "$OUT"

rm -rf "$FIXTURE_E"

# ---------------------------------------------------------------------------
# (f) A symlinked dotfile is never handed a bare `sed -i` against the link.
#     In-place sed renames the LINK to the .bak name and writes a new regular
#     file in its place, so the managed source keeps its uncommented export
#     while this machine looks fixed, and the following chmod follows the
#     moved link and changes the source's mode. A dotfile farm (stow,
#     chezmoi, yadm) is exactly where a shared .bashrc with a credential
#     lives, so the command must target the resolved file instead.
# ---------------------------------------------------------------------------
echo "== (f) a symlinked dotfile targets its resolved file =="

FIXTURE_F="$(mktemp -d)"
mkdir -p "$FIXTURE_F/.engram" "$FIXTURE_F/dotfiles"
printf '{\n  "server_url": "https://engram.xdev.es",\n  "token": "survivor-xyz"\n}\n' \
    > "$FIXTURE_F/.engram/cloud.json"
printf '# managed\nexport ENGRAM_CLOUD_TOKEN=survivor-xyz\n' > "$FIXTURE_F/dotfiles/bashrc"
ln -s "$FIXTURE_F/dotfiles/bashrc" "$FIXTURE_F/.bashrc"

run_install "$FIXTURE_F" "survivor-xyz"

assert_eq "(f) exits 1" "1" "$STATUS"
assert_match "(f) says the dotfile is a symlink" \
    "es un enlace simbólico" "$OUT"
assert_match "(f) the sed command targets the resolved file" \
    "$FIXTURE_F/dotfiles/bashrc" "$OUT"
assert_match "(f) the chmod targets the resolved file's backup" \
    "chmod 600 $FIXTURE_F/dotfiles/bashrc.bak" "$OUT"
assert_no_match "(f) no sed -i against the link itself" \
    "ENGRAM_CLOUD_)/# \\1/' $FIXTURE_F/.bashrc" "$OUT"
assert_no_match "(f) no chmod against the link's backup" \
    "chmod 600 $FIXTURE_F/.bashrc.bak" "$OUT"
assert_no_match "(f) never prints the token value" "survivor-xyz" "$OUT"

rm -rf "$FIXTURE_F"

# ---------------------------------------------------------------------------
# Real $HOME was never read or written by any of the above.
# ---------------------------------------------------------------------------
echo "== real \$HOME isolation =="

AFTER_REAL_HOME="$(_real_snapshot)"
assert_eq "real \$HOME files unchanged by the whole test run" "$BEFORE_REAL_HOME" "$AFTER_REAL_HOME"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
