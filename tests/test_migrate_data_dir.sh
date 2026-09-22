#!/usr/bin/env bash
# tests/test_migrate_data_dir.sh — plain-bash tests for
# bin/engram-migrate's instance_data_dir(): it must resolve an instance's
# data_dir from router.json and expand a leading "$HOME"/"~" using the same
# logic as lib/router.sh's router_expand_path, instead of re-parsing the
# config and re-expanding the path with sed of its own.
#
# Two sed defects motivate this file:
#   - the old $HOME/~ expansion used "#" as its sed delimiter, so a $HOME
#     containing "#" broke the substitution outright (see cases a/b below,
#     which deliberately give the fixture $HOME a "#");
#   - the old data_dir extraction matched only within a single line, so a
#     pretty-printed router.json (each instance spread over several lines)
#     could not be parsed at all (see case e below).
#
# Runs entirely against a stub `engram` binary in a throwaway sandbox: no
# real instance, daemon, router config, or cloud server is touched. Every
# invocation gets a fixture HOME and a scrubbed environment, and the real
# $HOME's top-level entries are hashed before and after as evidence nothing
# leaked out of the sandbox.
#
# Run with: bash tests/test_migrate_data_dir.sh
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

assert_status_zero() {
    if [[ "$2" -eq 0 ]]; then _pass "$1 (exit $2)"
    else _fail "$1" "esperado exit 0, obtenido $2 -- salida: $3"; fi
}
assert_status_nonzero() {
    if [[ "$2" -ne 0 ]]; then _pass "$1 (exit $2)"
    else _fail "$1" "esperado exit distinto de cero, obtenido 0"; fi
}
# Fixed-string (non-regex) substring check: the expected directories in this
# file contain characters ('#', '&', '|', space) that are meaningful to
# grep -E, so every literal comparison here uses grep -F.
assert_contains_literal() {  # desc literal-substring haystack
    if grep -Fq -- "$2" <<<"$3"; then _pass "$1"
    else _fail "$1" "no aparece la subcadena literal: $2"; fi
}
assert_lacks_literal() {  # desc literal-substring haystack
    if grep -Fq -- "$2" <<<"$3"; then _fail "$1" "aparece y no debería: $2"
    else _pass "$1"; fi
}
assert_log_empty() {  # desc
    if [[ ! -s "$LOG_FILE" ]]; then _pass "$1"
    else _fail "$1" "el log no está vacío: $(cat "$LOG_FILE")"; fi
}

# ---------------------------------------------------------------------------
# Real-$HOME safety net (same convention as test_migrate_source_pull.sh).
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

# Same stub `engram` as test_migrate_source_pull.sh: logs every invocation
# and fakes just enough output for engram-migrate to complete a full
# migration. These tests care about which data_dir got used (visible in the
# log's "<dir>|<args>" prefix and in the "origen:"/"destino:" banner), not
# about the migration steps themselves.
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

# Mirrors router_expand_path's own logic, used only to compute where this
# test harness must mkdir the real directory a given raw data_dir value is
# supposed to expand to -- it does not stand in for the code under test.
expand_for_test() {
    local v="$1" home="$2"
    case "$v" in
        '$HOME'/*) v="${home}${v#\$HOME}" ;;
        '~/'*) v="${home}/${v#\~/}" ;;
        '~') v="${home}" ;;
    esac
    printf '%s' "$v"
}

# Builds an isolated instance pair ("src" -> "dst") plus a repo dir named
# "test-proj". Unlike test_migrate_source_pull.sh's new_case(), the raw
# data_dir text written into router.json (what a person or install.sh would
# write) is kept separate from the actual absolute directory it must expand
# to (what gets mkdir'd and where the stub logs its calls), so tests can
# exercise $HOME/~ expansion and verbatim pass-through explicitly.
#
# Args: name raw_from_data_dir raw_to_data_dir [pretty]
# pretty=1 spreads each instance object over several lines, the shape
# python3 -m json.tool (or a hand edit) produces.
new_case() {
    local name="$1" raw_from="$2" raw_to="$3" pretty="${4:-0}"
    local case_dir="$SANDBOX/$name"
    CONFIG_DIR="$case_dir/config"
    REPO_DIR="$case_dir/repo/test-proj"
    LOG_FILE="$case_dir/engram.log"
    FIXTURE_HOME="$case_dir/fixture#home"
    mkdir -p "$CONFIG_DIR" "$REPO_DIR" "$FIXTURE_HOME"
    : > "$LOG_FILE"

    FROM_DIR="$(expand_for_test "$raw_from" "$FIXTURE_HOME")"
    TO_DIR="$(expand_for_test "$raw_to" "$FIXTURE_HOME")"
    mkdir -p "$FROM_DIR" "$TO_DIR"

    if [[ "$pretty" -eq 1 ]]; then
        cat > "$CONFIG_DIR/router.json" <<EOF
{
  "rules": [],
  "instances": {
    "src": {
      "data_dir": "$raw_from",
      "port": 7437,
      "autosync": false
    },
    "dst": {
      "data_dir": "$raw_to",
      "port": 7438,
      "autosync": false
    }
  }
}
EOF
    else
        cat > "$CONFIG_DIR/router.json" <<EOF
{
  "rules": [],
  "instances": {
    "src": { "data_dir": "$raw_from" },
    "dst": { "data_dir": "$raw_to" }
  }
}
EOF
    fi

    # Destination cloud.json: engram-migrate's own step 0 refuses to run
    # without one. Source is deliberately left without one (proceeds with a
    # stated reason, per test_migrate_source_pull.sh case 3) to keep these
    # cases focused on data_dir resolution.
    printf '{"server_url":"https://stub-cloud.invalid","token":"t"}\n' > "$TO_DIR/cloud.json"
}

run_migrate() {
    ( cd "$REPO_DIR" &&
      timeout 10 env -i \
        PATH="$STUB_BIN:/usr/bin:/bin" \
        HOME="$FIXTURE_HOME" \
        LC_ALL=C \
        ENGRAM_ROUTER_CONFIG_DIR="$CONFIG_DIR" \
        STUB_ENGRAM_LOG="$LOG_FILE" \
        "$MIGRATE" "$@" --yes </dev/null 2>&1 )
}

# --- a. "$HOME/..." data_dir is expanded to the real, absolute fixture path
echo "== data_dir con \"\$HOME/...\" se expande a la ruta absoluta =="
new_case home_expansion '$HOME/.local/share/engram-work' "$SANDBOX/home_expansion/to-plain"
out="$(run_migrate --from src --to dst)"; status=$?
assert_status_zero "termina con éxito" "$status" "$out"
assert_contains_literal "el banner de origen muestra la ruta expandida" \
    "($FROM_DIR)" "$out"
assert_contains_literal "el stub registra la invocación contra la ruta expandida" \
    "$FROM_DIR|sync" "$(cat "$LOG_FILE")"

# --- b. "~/..." data_dir is expanded the same way -------------------------
echo
echo "== data_dir con \"~/...\" se expande a la ruta absoluta =="
new_case tilde_expansion '~/.engram' "$SANDBOX/tilde_expansion/to-plain"
out="$(run_migrate --from src --to dst)"; status=$?
assert_status_zero "termina con éxito" "$status" "$out"
assert_contains_literal "el banner de origen muestra la ruta expandida" \
    "($FROM_DIR)" "$out"
assert_contains_literal "el stub registra la invocación contra la ruta expandida" \
    "$FROM_DIR|sync" "$(cat "$LOG_FILE")"

# --- c. An already-absolute path is returned unchanged ---------------------
# Deliberately contains "home" mid-string (not as a leading "$HOME"/"~"
# token) to guard against an expansion that matches too eagerly.
echo
echo "== una ruta ya absoluta se devuelve sin cambios =="
new_case absolute_passthrough "$SANDBOX/absolute_passthrough/my-home-backup" \
    "$SANDBOX/absolute_passthrough/to-plain"
out="$(run_migrate --from src --to dst)"; status=$?
assert_status_zero "termina con éxito" "$status" "$out"
assert_contains_literal "el banner de origen muestra la misma ruta absoluta" \
    "($FROM_DIR)" "$out"

# --- d. A data_dir with '#', '&', '|' and a space survives verbatim --------
echo
echo "== un data_dir con '#', '&', '|' y un espacio se devuelve byte a byte =="
special_dir="$SANDBOX/special_chars/data#1 & more|stuff"
mkdir -p "$SANDBOX/special_chars"
new_case special_chars "$special_dir" "$SANDBOX/special_chars/to-plain"
out="$(run_migrate --from src --to dst)"; status=$?
assert_status_zero "termina con éxito" "$status" "$out"
assert_contains_literal "el banner de origen muestra la ruta exacta con sus caracteres especiales" \
    "($FROM_DIR)" "$out"
assert_contains_literal "el stub registra la invocación contra la ruta exacta" \
    "$FROM_DIR|sync" "$(cat "$LOG_FILE")"

# --- e. A pretty-printed router.json (multi-line instances) still resolves -
echo
echo "== un router.json formateado en varias líneas por instancia también resuelve =="
new_case pretty_printed "$SANDBOX/pretty_printed/from-plain" "$SANDBOX/pretty_printed/to-plain" 1
out="$(run_migrate --from src --to dst)"; status=$?
assert_status_zero "termina con éxito pese al formato multilínea" "$status" "$out"
assert_contains_literal "imprime el banner final" "=== Hecho ===" "$out"
assert_contains_literal "el banner de origen muestra la ruta correcta" \
    "($FROM_DIR)" "$out"

# --- f. An unknown instance name fails closed, with no stray invocation ----
echo
echo "== una instancia desconocida falla sin invocar engram =="
new_case unknown_instance "$SANDBOX/unknown_instance/from-plain" "$SANDBOX/unknown_instance/to-plain"
out="$(run_migrate --from ghost --to dst)"; status=$?
assert_status_nonzero "sale con código distinto de cero" "$status"
assert_contains_literal "explica que la instancia no está en el config" \
    "la instancia 'ghost' no está en" "$out"
assert_log_empty "no se invoca engram en absoluto"

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
