#!/usr/bin/env bash
# tests/test_migrate_source_pull.sh — plain-bash tests for the source-cloud
# pull step in bin/engram-migrate: it must pull the SOURCE's own cloud into
# its local database before anything is exported, and must fail closed
# (stop before enroll/push) when that pull cannot be completed.
#
# Runs entirely against a stub `engram` binary in a throwaway sandbox: no
# real instance, daemon, router config, or cloud server is touched. Every
# invocation gets a fixture HOME and a scrubbed environment, and the real
# $HOME's top-level entries are hashed before and after as evidence nothing
# leaked out of the sandbox.
#
# Run with: bash tests/test_migrate_source_pull.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE="$ROOT_DIR/bin/engram-migrate"

PASS=0; FAIL=0
_pass() { printf '  ok      %s\n' "$1"; PASS=$((PASS+1)); }
_fail() {
    printf '  FAILED  %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '            %s\n' "$2"
    FAIL=$((FAIL+1))
}

assert_match() {  # desc pattern text
    if grep -qE "$2" <<<"$3"; then _pass "$1"
    else _fail "$1" "no aparece /$2/ en la salida"; fi
}
assert_status_zero() {
    if [[ "$2" -eq 0 ]]; then _pass "$1 (exit $2)"
    else _fail "$1" "esperado exit 0, obtenido $2"; fi
}
assert_status_nonzero() {
    if [[ "$2" -ne 0 ]]; then _pass "$1 (exit $2)"
    else _fail "$1" "esperado exit distinto de cero, obtenido 0"; fi
}
assert_log_has() {  # desc exact-log-line
    if grep -Fxq "$2" "$LOG_FILE"; then _pass "$1"
    else _fail "$1" "no aparece en el log: $2"; fi
}
assert_log_lacks() {  # desc substring
    if grep -Fq "$2" "$LOG_FILE"; then _fail "$1" "aparece en el log y no debería: $2"
    else _pass "$1"; fi
}
assert_log_lacks_line() {  # desc exact-log-line (avoids matching a longer
                            # call that merely starts with the same prefix,
                            # e.g. plain "sync" vs "sync --import --cloud …")
    if grep -Fxq "$2" "$LOG_FILE"; then _fail "$1" "aparece en el log y no debería: $2"
    else _pass "$1"; fi
}
assert_log_order() {  # desc exact-log-line-first exact-log-line-second
    local l1 l2
    l1="$(grep -Fxn "$2" "$LOG_FILE" | head -1 | cut -d: -f1)"
    l2="$(grep -Fxn "$3" "$LOG_FILE" | head -1 | cut -d: -f1)"
    if [[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]]; then _pass "$1"
    else _fail "$1" "primero='${l1:-<ausente>}' segundo='${l2:-<ausente>}'"; fi
}

# ---------------------------------------------------------------------------
# Real-$HOME safety net. Hashes only the top-level entry NAMES (not mtimes or
# contents), which is deliberately insensitive to the live engram@trabajo /
# engram@personal daemons writing inside their own data dirs during the run —
# it only flags something new appearing or disappearing directly under $HOME.
# ---------------------------------------------------------------------------
REAL_HOME="$HOME"
home_listing_hash() {
    find "$REAL_HOME" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort | sha256sum | awk '{print $1}'
}
BEFORE_HOME_HASH="$(home_listing_hash)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

STUB_BIN="$SANDBOX/stubbin"
mkdir -p "$STUB_BIN"

# A stub of the real `engram` binary. Logs every invocation as
# "<ENGRAM_DATA_DIR>|<args>" to $STUB_ENGRAM_LOG, and fakes just enough
# output for engram-migrate to parse. Placed first on PATH so
# resolve_real_engram() in engram-migrate picks it up directly (it carries
# no 'engram-router-shim' marker, so it is never mistaken for the shim).
cat > "$STUB_BIN/engram" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
: "${STUB_ENGRAM_LOG:?STUB_ENGRAM_LOG not set}"
printf '%s|%s\n' "${ENGRAM_DATA_DIR:-}" "$*" >> "$STUB_ENGRAM_LOG"

case "${1:-} ${2:-}" in
    "cloud status")
        if [[ -r "${ENGRAM_DATA_DIR:-}/cloud.json" ]]; then
            printf 'Cloud status: configured (target=cloud)\n'
            printf 'Server: https://stub-cloud.invalid\n'
            printf 'Server source: cloud.json\n'
            printf 'Auth status: ready (token read from cloud.json)\n'
        else
            printf 'Cloud status: not configured (no effective server URL)\n'
        fi
        exit 0
        ;;
    "cloud enroll")
        printf 'Enrolled project "%s".\n' "${3:-}"
        exit 0
        ;;
    "cloud unenroll")
        printf 'Unenrolled project "%s".\n' "${3:-}"
        exit 0
        ;;
esac

if [[ "${1:-}" == "sync" ]]; then
    shift
    has_import=0; has_cloud=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --import) has_import=1; shift ;;
            --cloud)  has_cloud=1;  shift ;;
            --project) shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ $has_cloud -eq 1 && $has_import -eq 1 ]]; then
        if [[ -e "${ENGRAM_DATA_DIR:-}/pull_should_fail" ]]; then
            printf 'engram: cloud sync blocked_unenrolled: stub forced failure\n' >&2
            exit 1
        fi
        printf 'Pulled 2 remote chunks.\n'
        exit 0
    elif [[ $has_cloud -eq 1 ]]; then
        printf 'Pushed to cloud.\n'
        exit 0
    elif [[ $has_import -eq 1 ]]; then
        printf 'Observations: 2\n'
        exit 0
    else
        mkdir -p .engram/chunks
        printf 'Observations: 2\n'
        exit 0
    fi
fi

printf 'stub-engram: unrecognized invocation: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/engram"

# Builds a fresh, isolated instance pair ("src" -> "dst") plus a repo dir
# named "test-proj" (no git remote, so engram-migrate falls back to the
# directory name for project detection). Sets FROM_DIR, TO_DIR, CONFIG_DIR,
# REPO_DIR, LOG_FILE for the caller.
new_case() {
    local name="$1"
    local case_dir="$SANDBOX/$name"
    FROM_DIR="$case_dir/from"; TO_DIR="$case_dir/to"
    CONFIG_DIR="$case_dir/config"
    REPO_DIR="$case_dir/repo/test-proj"
    LOG_FILE="$case_dir/engram.log"
    FIXTURE_HOME="$case_dir/fixture-home"
    mkdir -p "$FROM_DIR" "$TO_DIR" "$CONFIG_DIR" "$REPO_DIR" "$FIXTURE_HOME"
    : > "$LOG_FILE"

    # Single line per instance: this is the exact shape install.sh's
    # write_router_config() emits (see instance_lines+= in install.sh),
    # which is what instance_data_dir()'s line-based sed depends on.
    cat > "$CONFIG_DIR/router.json" <<EOF
{
  "rules": [],
  "instances": {
    "src": { "data_dir": "$FROM_DIR" },
    "dst": { "data_dir": "$TO_DIR" }
  }
}
EOF

    # The destination always has a cloud.json: engram-migrate's own step 0
    # refuses to run at all without one, and that is not what this suite
    # tests.
    printf '{"server_url":"https://stub-cloud.invalid","token":"t"}\n' > "$TO_DIR/cloud.json"
}

# Runs engram-migrate for the current case: fixture HOME, fixture router
# config, stub-first PATH, a fully scrubbed environment (env -i drops any
# live ENGRAM_CLOUD_* along with everything else), closed stdin so no prompt
# can block, and a hard timeout so a hang fails the suite instead of the
# terminal.
run_migrate() {
    ( cd "$REPO_DIR" &&
      timeout 10 env -i \
        PATH="$STUB_BIN:/usr/bin:/bin" \
        HOME="$FIXTURE_HOME" \
        LC_ALL=C \
        ENGRAM_ROUTER_CONFIG_DIR="$CONFIG_DIR" \
        STUB_ENGRAM_LOG="$LOG_FILE" \
        "$MIGRATE" --from src --to dst --yes "$@" </dev/null 2>&1 )
}

PULL_LINE="sync --import --cloud --project test-proj"
EXPORT_LINE="sync"
IMPORT_LINE="sync --import"
ENROLL_SUBSTR="cloud enroll test-proj"
PUSH_LINE="sync --cloud --project test-proj"
UNENROLL_SUBSTR="cloud unenroll test-proj"

# --- 1. Success path: pull runs against the source, before export, and the
#        whole migration still completes end to end -------------------------
echo "== Migración completa: pull contra el origen antes del export =="
new_case ok
printf '{"server_url":"https://stub-cloud.invalid","token":"t"}\n' > "$FROM_DIR/cloud.json"
out="$(run_migrate)"; status=$?
assert_status_zero "termina con éxito" "$status"
assert_match "imprime el banner final" '=== Hecho ===' "$out"
assert_log_has "el pull se registra contra el directorio de datos del ORIGEN" \
    "$FROM_DIR|$PULL_LINE"
assert_log_order "el pull precede al export" \
    "$FROM_DIR|$PULL_LINE" "$FROM_DIR|$EXPORT_LINE"
assert_log_order "el export precede al import en destino" \
    "$FROM_DIR|$EXPORT_LINE" "$TO_DIR|$IMPORT_LINE"
assert_log_order "el import precede al enrolado" \
    "$TO_DIR|$IMPORT_LINE" "$TO_DIR|cloud enroll test-proj"
assert_log_order "el enrolado precede al empujado" \
    "$TO_DIR|cloud enroll test-proj" "$TO_DIR|$PUSH_LINE"
assert_log_order "el empujado precede al desenrolado en origen" \
    "$TO_DIR|$PUSH_LINE" "$FROM_DIR|cloud unenroll test-proj"

# --- 2. A blocked/failing pull stops the migration before enroll/push ------
echo
echo "== Un pull bloqueado detiene la migración, sin llegar a enrolar/empujar =="
new_case blocked
printf '{"server_url":"https://stub-cloud.invalid","token":"t"}\n' > "$FROM_DIR/cloud.json"
touch "$FROM_DIR/pull_should_fail"
out="$(run_migrate)"; status=$?
assert_status_nonzero "sale con código distinto de cero" "$status"
assert_match "explica que el pull del origen falló" 'no se pudo traer del cloud de origen' "$out"
assert_log_has "sí se intentó el pull" "$FROM_DIR|$PULL_LINE"
assert_log_lacks_line "no llega a exportar" "$FROM_DIR|$EXPORT_LINE"
assert_log_lacks_line "no llega a importar en destino" "$TO_DIR|$IMPORT_LINE"
assert_log_lacks "no llega a enrolar en destino" "$ENROLL_SUBSTR"
assert_log_lacks "no llega a empujar" "$TO_DIR|$PUSH_LINE"
assert_log_lacks "no llega a desenrolar en origen" "$UNENROLL_SUBSTR"

# --- 3. No cloud.json at the source: proceeds with a stated reason ---------
echo
echo "== Origen sin cloud.json: continúa con un motivo explícito =="
new_case no_cloud
out="$(run_migrate)"; status=$?
assert_status_zero "termina con éxito" "$status"
assert_match "explica que el origen no tiene cloud.json" 'origen sin cloud\.json' "$out"
assert_log_lacks "nunca intenta el pull (no hay nube de la que traer)" "$PULL_LINE"
assert_log_has "sí llega a exportar" "$FROM_DIR|$EXPORT_LINE"
assert_log_has "sí llega a enrolar en destino" "$TO_DIR|$ENROLL_SUBSTR"
assert_match "imprime el banner final" '=== Hecho ===' "$out"

# --- 4. --skip-source-pull bypasses a pull that would otherwise block ------
echo
echo "== --skip-source-pull omite el pull y avisa del riesgo =="
new_case skip
printf '{"server_url":"https://stub-cloud.invalid","token":"t"}\n' > "$FROM_DIR/cloud.json"
touch "$FROM_DIR/pull_should_fail"
out="$(run_migrate --skip-source-pull)"; status=$?
assert_status_zero "termina con éxito" "$status"
assert_match "avisa de que se omite el pull" 'skip-source-pull' "$out"
assert_log_lacks "no intenta el pull en absoluto" "$PULL_LINE"
assert_log_has "sí llega a exportar" "$FROM_DIR|$EXPORT_LINE"
assert_log_has "sí llega a empujar" "$TO_DIR|$PUSH_LINE"
assert_match "imprime el banner final" '=== Hecho ===' "$out"

# --- Real-$HOME safety net --------------------------------------------------
echo
AFTER_HOME_HASH="$(home_listing_hash)"
if [[ "$AFTER_HOME_HASH" == "$BEFORE_HOME_HASH" ]]; then
    _pass "el listado de nivel superior del \$HOME real no cambió"
else
    _fail "el listado de nivel superior del \$HOME real no cambió" \
        "antes=$BEFORE_HOME_HASH después=$AFTER_HOME_HASH"
fi

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
