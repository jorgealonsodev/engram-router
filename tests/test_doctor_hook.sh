#!/usr/bin/env bash
#
# tests/test_doctor_hook.sh — bin/engram-doctor's post-shim-retirement
# checks: check_no_shadowing (replaces check_path_precedence) and
# check_hook_active (new).
#
# Covers:
#   - check_no_shadowing: ok when "engram" resolves to a non-marker binary,
#     fail with the retired-shim message when it resolves to a marker file,
#     fail with the "not found" message when PATH has no "engram" at all
#   - check_hook_active, all five branches: resolved+matching (ok), resolved+
#     unset (warn + recommended eval line matching $SHELL), resolved+wrong
#     (fail), unresolved+unset (ok), unresolved+set (warn)
#   - trailing-slash tolerance in the ENGRAM_DATA_DIR / ROUTER_DATA_DIR
#     comparison
#   - the recommended eval line matches $SHELL (bash vs. zsh vs. unknown)
#
# Test-safety (same discipline as tests/test_hook.sh):
#   - every doctor run uses a fixture HOME, ENGRAM_ROUTER_CONFIG and
#     ENGRAM_ROUTER_LIB, never the real ones
#   - ENGRAM_CLOUD_* is scrubbed from every run's environment
#   - the real $HOME's engram-router files are snapshotted before and after
#     to prove they were not touched
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
assert_not_match() {  # label pattern text
    if grep -qE "$2" <<<"$3"; then _fail "$1" "unexpectedly matches /$2/ — got: $3"
    else _pass "$1"; fi
}

# ---------------------------------------------------------------------------
# Real $HOME safety net (same pattern as tests/test_hook.sh).
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
# Fixture router.json: two instances, "trabajo" and "personal". Only
# "trabajo" has a matching rule; "personal"'s data dir is reused below as a
# deliberately-wrong ENGRAM_DATA_DIR value.
# ---------------------------------------------------------------------------
CONFIG_DIR="$FIXTURE_HOME/.config/engram-router"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/router.json"
TRABAJO_DATA_DIR="$FIXTURE_HOME/.local/share/engram-trabajo"
PERSONAL_DATA_DIR="$FIXTURE_HOME/.local/share/engram-personal"

cat >"$CONFIG_FILE" <<EOF
{
  "rules": [
    { "prefix": "github.com/mi-empresa", "instance": "trabajo" }
  ],
  "instances": {
    "trabajo": { "data_dir": "$TRABAJO_DATA_DIR", "port": 7438, "autosync": true },
    "personal": { "data_dir": "$PERSONAL_DATA_DIR", "port": 7439, "autosync": true }
  }
}
EOF

# ---------------------------------------------------------------------------
# Fixture git repos: one matches the "trabajo" rule, one matches nothing.
# ---------------------------------------------------------------------------
WORK_REPO="$FIXTURE/work_repo"
git init -q "$WORK_REPO"
git -C "$WORK_REPO" remote add origin git@github.com:mi-empresa/proyecto.git

UNMATCHED_REPO="$FIXTURE/unmatched_repo"
git init -q "$UNMATCHED_REPO"
git -C "$UNMATCHED_REPO" remote add origin git@github.com:otro-tercero/proyecto.git

# ---------------------------------------------------------------------------
# Stub "real" engram (no marker) — plausibly answers --version/version so
# check_engram_version has something to parse.
# ---------------------------------------------------------------------------
REALBIN="$FIXTURE/realbin"
mkdir -p "$REALBIN"
cat >"$REALBIN/engram" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version|version) printf 'engram version 2.0.0\n' ;;
    *) printf 'stub engram %s\n' "$*" ;;
esac
EOF
chmod +x "$REALBIN/engram"

# ---------------------------------------------------------------------------
# A marker-carrying leftover shim, same marker install.sh/uninstall.sh look
# for.
# ---------------------------------------------------------------------------
MARKERBIN="$FIXTURE/markerbin"
mkdir -p "$MARKERBIN"
cat >"$MARKERBIN/engram" <<'EOF'
#!/usr/bin/env bash
# engram-router-shim: identifies this file to the other tools.
printf 'stale shim %s\n' "$*"
EOF
chmod +x "$MARKERBIN/engram"

# ---------------------------------------------------------------------------
# PATH with every "engram" executable stripped out, so a fixture PATH can be
# built without ever finding this host's real one.
# ---------------------------------------------------------------------------
_strip_engram_from_path() {
    local p="$1" d out=()
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ -x "$d/engram" ]] && continue
        out+=("$d")
    done < <(printf '%s' "$p" | tr ':' '\n')
    (IFS=:; printf '%s' "${out[*]}")
}
NO_ENGRAM_PATH="$(_strip_engram_from_path "$REAL_PATH")"
WITH_REAL_PATH="$REALBIN:$NO_ENGRAM_PATH"
WITH_MARKER_PATH="$MARKERBIN:$NO_ENGRAM_PATH"

# ---------------------------------------------------------------------------
# Doctor runner: cd's into $1, runs bin/engram-doctor with a fixture
# HOME/config/lib/PATH, ENGRAM_DATA_DIR set to $3 (or unset when $3 is the
# literal string "UNSET"), and $SHELL set to $4 when given. Leaves DOC_OUT
# (captured stdout+stderr) and DOC_RC (exit status) for the caller.
# ---------------------------------------------------------------------------
_run_doctor() {  # dir path_override engram_data_dir_or_UNSET [shell_name]
    local dir="$1" path_override="$2" data_dir="$3" shell_name="${4:-}"
    DOC_OUT="$(mktemp -p "$FIXTURE")"
    (
        for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
        cd "$dir" || exit 90
        export HOME="$FIXTURE_HOME"
        export ENGRAM_ROUTER_CONFIG="$CONFIG_FILE"
        export ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh"
        export PATH="$path_override"
        if [[ "$data_dir" == "UNSET" ]]; then
            unset ENGRAM_DATA_DIR
        else
            export ENGRAM_DATA_DIR="$data_dir"
        fi
        if [[ -n "$shell_name" ]]; then
            export SHELL="$shell_name"
        else
            unset SHELL
        fi
        bash "$ROOT_DIR/bin/engram-doctor"
    ) >"$DOC_OUT" 2>&1
    DOC_RC=$?
}

# ===========================================================================
# check_no_shadowing
# ===========================================================================
echo "== check_no_shadowing: 'engram' resolves to the real binary =="
_run_doctor "$UNMATCHED_REPO" "$WITH_REAL_PATH" "UNSET"
assert_match "output reports nothing shadows 'engram'" \
    "nada lo ensombrece" "$(cat "$DOC_OUT")"

echo
echo "== check_no_shadowing: a marker-carrying shim is first on PATH =="
_run_doctor "$UNMATCHED_REPO" "$WITH_MARKER_PATH" "UNSET"
assert_match "output reports the retired-shim failure" \
    "shim retirado" "$(cat "$DOC_OUT")"
assert_eq "doctor exits non-zero when a retired shim shadows 'engram'" \
    "1" "$DOC_RC"

echo
echo "== check_no_shadowing: no 'engram' anywhere on PATH =="
_run_doctor "$UNMATCHED_REPO" "$NO_ENGRAM_PATH" "UNSET"
assert_match "output reports no real 'engram' binary was found" \
    "no se encontró el binario real 'engram' en PATH" "$(cat "$DOC_OUT")"

# ===========================================================================
# check_hook_active
# ===========================================================================
echo
echo "== check_hook_active: resolved dir, ENGRAM_DATA_DIR matches =="
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "$TRABAJO_DATA_DIR"
assert_match "output reports the hook is active for 'trabajo'" \
    "hook activo: ENGRAM_DATA_DIR apunta a la instancia 'trabajo'" "$(cat "$DOC_OUT")"
assert_eq "doctor exits 0 when the hook is active and matches" "0" "$DOC_RC"

echo
echo "== check_hook_active: trailing slash is tolerated in the comparison =="
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "${TRABAJO_DATA_DIR}/"
assert_match "a trailing slash on ENGRAM_DATA_DIR still counts as a match" \
    "hook activo: ENGRAM_DATA_DIR apunta a la instancia 'trabajo'" "$(cat "$DOC_OUT")"
assert_eq "doctor exits 0 with a trailing-slash match" "0" "$DOC_RC"

echo
echo "== check_hook_active: resolved dir, ENGRAM_DATA_DIR unset (hook not loaded) =="
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "UNSET" "/bin/bash"
assert_match "output warns the hook is not loaded, naming the resolved instance" \
    "el hook de shell no está cargado en esta shell: este directorio resuelve a 'trabajo' pero ENGRAM_DATA_DIR no está definido" \
    "$(cat "$DOC_OUT")"

echo
echo "== check_hook_active: resolved dir, ENGRAM_DATA_DIR points elsewhere =="
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "$PERSONAL_DATA_DIR"
assert_match "output reports the mismatch as a failure" \
    "ENGRAM_DATA_DIR \\($PERSONAL_DATA_DIR\\) no coincide con la instancia que resuelve este directorio \\('trabajo'" \
    "$(cat "$DOC_OUT")"
assert_eq "doctor exits non-zero when ENGRAM_DATA_DIR points at the wrong instance" \
    "1" "$DOC_RC"

echo
echo "== check_hook_active: unmatched dir, ENGRAM_DATA_DIR unset =="
_run_doctor "$UNMATCHED_REPO" "$WITH_REAL_PATH" "UNSET"
assert_match "output reports the correct unrouted+unset state as ok" \
    "este directorio no resuelve a ninguna instancia; ENGRAM_DATA_DIR sin definir \\(correcto\\)" \
    "$(cat "$DOC_OUT")"
assert_eq "doctor exits 0 for an unrouted dir with ENGRAM_DATA_DIR unset" "0" "$DOC_RC"

echo
echo "== check_hook_active: unmatched dir, ENGRAM_DATA_DIR set (stale) =="
_run_doctor "$UNMATCHED_REPO" "$WITH_REAL_PATH" "$TRABAJO_DATA_DIR"
assert_match "output warns ENGRAM_DATA_DIR looks stale for this directory" \
    "ENGRAM_DATA_DIR está definido \\($TRABAJO_DATA_DIR\\) pero este directorio no resuelve a ninguna instancia" \
    "$(cat "$DOC_OUT")"
assert_eq "doctor exits 0 for a stale ENGRAM_DATA_DIR (warning, not a failure)" \
    "0" "$DOC_RC"

# ===========================================================================
# check_current_repo_routing — regression for the subshell dropping the
# ROUTER_* globals set inside _resolve_current_dir_routing's command
# substitution (R2-subshell-global-contract / R4-subshell-drops-router-globals).
# ===========================================================================
echo
echo "== check_current_repo_routing: full doctor run names the resolved instance =="
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "$TRABAJO_DATA_DIR"
assert_match "'Enrutamiento del repositorio actual' section names the resolved instance" \
    "instancia resuelta: trabajo" "$(cat "$DOC_OUT")"

echo
echo "== check_current_repo_routing: called alone after a global reset =="
ALONE_OUT="$(mktemp -p "$FIXTURE")"
(
    for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
    cd "$WORK_REPO" || exit 90
    export HOME="$FIXTURE_HOME"
    export ENGRAM_ROUTER_CONFIG="$CONFIG_FILE"
    export ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh"
    export PATH="$WITH_REAL_PATH"
    unset ENGRAM_DATA_DIR
    # shellcheck source=/dev/null
    source "$ROOT_DIR/bin/engram-doctor" >/dev/null 2>&1
    # main() is guarded and does not run under source, so lib/router.sh (the
    # source of router_resolve) never got sourced above; do what main() does.
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/router.sh"
    ROUTER_INSTANCE=
    ROUTER_DATA_DIR=
    ROUTER_MATCHED_RULE=
    check_current_repo_routing
) >"$ALONE_OUT" 2>&1
assert_match "check_current_repo_routing alone still resolves the instance (not stale/blank)" \
    "instancia resuelta: trabajo" "$(cat "$ALONE_OUT")"

# ===========================================================================
# Recommended eval line matches $SHELL.
# ===========================================================================
echo
echo "== recommended eval line matches \$SHELL (hook-not-loaded branch) =="

_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "UNSET" "/bin/bash"
out_bash="$(cat "$DOC_OUT")"
assert_match "SHELL=/bin/bash: bash eval line is printed" \
    'eval "\$\(engram-router hook bash\)"' "$out_bash"
assert_not_match "SHELL=/bin/bash: zsh eval line is not printed" \
    'engram-router hook zsh' "$out_bash"

_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "UNSET" "/usr/bin/zsh"
out_zsh="$(cat "$DOC_OUT")"
assert_match "SHELL=/usr/bin/zsh: zsh eval line is printed" \
    'eval "\$\(engram-router hook zsh\)"' "$out_zsh"
assert_not_match "SHELL=/usr/bin/zsh: bash eval line is not printed" \
    'engram-router hook bash' "$out_zsh"

# Bash auto-populates $SHELL from the login shell when it starts with no
# SHELL in its environment (verified: `env -u SHELL bash -c 'echo $SHELL'`
# still prints something), so an unrecognized shell must be tested with an
# explicit, non-bash/zsh value rather than by leaving $SHELL unset.
_run_doctor "$WORK_REPO" "$WITH_REAL_PATH" "UNSET" "/usr/bin/fish"
out_unknown="$(cat "$DOC_OUT")"
assert_match "unrecognized \$SHELL (fish): bash eval line is printed" \
    'engram-router hook bash' "$out_unknown"
assert_match "unrecognized \$SHELL (fish): zsh eval line is also printed" \
    'engram-router hook zsh' "$out_unknown"

# ===========================================================================
# Real $HOME is untouched.
# ===========================================================================
echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's engram-router files are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
