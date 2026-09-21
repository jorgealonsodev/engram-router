#!/usr/bin/env bash
# tests/test_install_existing_root_detection.sh — covers the P9 fix in
# install.sh's ask_one_instance(): detecting an existing Engram installation
# root BEFORE offering a default for a brand-new instance.
#
# The bug this guards against: the directory prompt's default was always a
# brand-new empty directory ($HOME/.local/share/engram-<name>). Pressing
# Enter there started the instance on an empty database while an existing
# installation's memories (typically ~/.engram) sat unreferenced — nothing
# failed, nothing warned. Detection must fire before the prompt shows any
# default, so an empty answer is refused and re-asked instead of silently
# picking the empty directory.
#
# No framework: each check prints ok/FAIL and the script exits non-zero on
# any failure. Run with: bash tests/test_install_existing_root_detection.sh
#
# ask_one_instance() itself does not care whether stdin is a terminal (only
# the outer ask_instances() gates prompting on `[[ -t 0 ]]`), so these tests
# call it directly with piped input after sourcing install.sh's function
# definitions — dropping install.sh's own trailing `main "$@"` line so
# sourcing it never runs the installer. Every scenario runs in a disposable
# fixture HOME, with every real ENGRAM_CLOUD_* export scrubbed from its own
# subshell environment, exactly as tests/test_install_token_warning.sh does.
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

# _make_fixture_db PATH OBS_COUNT PROJECT_COUNT
# Builds a minimal but schema-accurate observations table (same columns
# _describe_engram_root() reads) with OBS_COUNT live rows spread across
# PROJECT_COUNT distinct projects, plus one soft-deleted row that must NOT
# be counted.
_make_fixture_db() {
    local db="$1" obs="$2" projects="$3"
    sqlite3 "$db" <<SQL
CREATE TABLE observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT, type TEXT, title TEXT, content TEXT, tool_name TEXT,
    project TEXT, scope TEXT DEFAULT 'project', deleted_at TEXT
);
SQL
    local i proj
    for ((i = 1; i <= obs; i++)); do
        proj="proj-$(( (i - 1) % projects ))"
        sqlite3 "$db" \
            "INSERT INTO observations (session_id,type,title,content,project,scope) VALUES ('s','fact','t$i','c$i','$proj','project');"
    done
    sqlite3 "$db" \
        "INSERT INTO observations (session_id,type,title,content,project,scope,deleted_at) VALUES ('s','fact','del','del','proj-0','project','2020-01-01');"
}

# run_ask_one_instance FIXTURE_HOME INSTANCE_DIRS_CSV NAME INPUT [PATH]
# Runs ask_one_instance() in a fresh bash subprocess: sources install.sh's
# functions (dropping its trailing `main "$@"`), stubs ask_namespaces_for
# (namespaces are out of scope here), pre-seeds INSTANCE_DIRS from a
# comma-separated list, feeds INPUT on stdin, then prints the resulting
# $ASKED_DIR tagged on its own line so the harness can separate it from the
# prompt transcript. Sets OUT (the prompt transcript) and ASKED_DIR.
run_ask_one_instance() {
    local fixture_home="$1" instance_dirs_csv="$2" name="$3" input="$4"
    local path_override="${5:-$PATH}"

    local harness raw
    harness="$(mktemp)"
    cat > "$harness" <<'HARNESS'
set -uo pipefail
# shellcheck source=/dev/null
source <(sed '$d' "$INSTALL_SH_PATH")
ask_namespaces_for() { printf ''; }
INSTANCE_DIRS=()
if [[ -n "$INSTANCE_DIRS_CSV" ]]; then
    IFS=',' read -r -a INSTANCE_DIRS <<< "$INSTANCE_DIRS_CSV"
fi
ask_one_instance "$INSTANCE_NAME"
printf '___ASKED_DIR___%s\n' "$ASKED_DIR"
HARNESS

    # `timeout` is load-bearing, not caution: a prompt that re-asks an
    # exhausted stream consumes no input and never returns, so without it a
    # non-terminating regression hangs the whole suite instead of failing
    # one check. STATUS 124 is what that looks like.
    raw="$(timeout 20 env "${_scrub_flags[@]}" \
        "HOME=$fixture_home" \
        "PATH=$path_override" \
        INSTALL_SH_PATH="$INSTALL_SH" \
        INSTANCE_DIRS_CSV="$instance_dirs_csv" \
        INSTANCE_NAME="$name" \
        bash "$harness" <<<"$input" 2>&1)"
    STATUS=$?
    rm -f "$harness"

    ASKED_DIR="$(sed -n 's/^___ASKED_DIR___//p' <<<"$raw" | tail -1)"
    OUT="$(grep -v '^___ASKED_DIR___' <<<"$raw")"
}

# Snapshot of real-$HOME files this feature reads, taken before any
# scenario runs and compared again at the end — proof no fixture ever
# leaked into the real $HOME.
_real_snapshot() {
    for p in "$HOME/.engram/engram.db" "$HOME/.engram/cloud.json" "$HOME/.config/engram-router/router.json"; do
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
# (a) Unclaimed existing root detected -> no default offered; an empty
#     answer is refused and re-asked rather than silently accepted.
# ---------------------------------------------------------------------------
echo "== (a) unclaimed existing root -> no default, empty input re-asks =="

FIXTURE_A="$(mktemp -d)"
mkdir -p "$FIXTURE_A/.engram"
_make_fixture_db "$FIXTURE_A/.engram/engram.db" 4 3

run_ask_one_instance "$FIXTURE_A" "" "work" $'\n~/.engram\n'

assert_match "(a) reports detection" "DETECTADA una instalación de Engram existente" "$OUT"
# shellcheck disable=SC2088
assert_match "(a) shows the candidate path" "~/.engram" "$OUT"
assert_match "(a) reports observation count" "4 observaciones" "$OUT"
assert_match "(a) reports project count" "3 proyectos" "$OUT"
assert_match "(a) refuses an empty answer" "No se acepta un valor vacío" "$OUT"
assert_eq "(a) adopts the typed path after the re-ask" "$FIXTURE_A/.engram" "$ASKED_DIR"

rm -rf "$FIXTURE_A"

# ---------------------------------------------------------------------------
# (b) Typing the exact detected path adopts it directly (no empty retry
#     needed first).
# ---------------------------------------------------------------------------
echo "== (b) typing the path adopts it =="

FIXTURE_B="$(mktemp -d)"
mkdir -p "$FIXTURE_B/.engram"
_make_fixture_db "$FIXTURE_B/.engram/engram.db" 1 1

run_ask_one_instance "$FIXTURE_B" "" "work" "$FIXTURE_B/.engram"$'\n'

assert_eq "(b) ASKED_DIR is the adopted root" "$FIXTURE_B/.engram" "$ASKED_DIR"
assert_match "(b) reuse note is printed" "Reutiliza una instalación existente" "$OUT"

rm -rf "$FIXTURE_B"

# ---------------------------------------------------------------------------
# (c) Typing 'nueva' selects the standard new directory
#     ($HOME/.local/share/engram-<name>), not the detected root.
# ---------------------------------------------------------------------------
echo "== (c) 'nueva' produces the standard new directory =="

FIXTURE_C="$(mktemp -d)"
mkdir -p "$FIXTURE_C/.engram"
_make_fixture_db "$FIXTURE_C/.engram/engram.db" 1 1

run_ask_one_instance "$FIXTURE_C" "" "work" $'nueva\n'

assert_eq "(c) ASKED_DIR is the standard new directory" \
    "$FIXTURE_C/.local/share/engram-work" "$ASKED_DIR"

rm -rf "$FIXTURE_C"

# ---------------------------------------------------------------------------
# (d) No existing root detected -> original default-offering prompt is
#     unchanged: Enter accepts the standard new directory.
# ---------------------------------------------------------------------------
echo "== (d) no existing root -> original default prompt preserved =="

FIXTURE_D="$(mktemp -d)"
# Deliberately no ~/.engram at all.

run_ask_one_instance "$FIXTURE_D" "" "work" $'\n'

assert_no_match "(d) no detection banner" "DETECTADA una instalación" "$OUT"
assert_eq "(d) Enter accepts the standard new directory" \
    "$FIXTURE_D/.local/share/engram-work" "$ASKED_DIR"

rm -rf "$FIXTURE_D"

# ---------------------------------------------------------------------------
# (e) A root already claimed by an instance configured earlier in this run
#     (tracked via INSTANCE_DIRS, the same array push_instance fills) is not
#     offered again for the next instance; the prompt returns to its normal
#     default behaviour.
# ---------------------------------------------------------------------------
echo "== (e) a root claimed earlier this run is not re-offered =="

FIXTURE_E="$(mktemp -d)"
mkdir -p "$FIXTURE_E/.engram"
_make_fixture_db "$FIXTURE_E/.engram/engram.db" 1 1

run_ask_one_instance "$FIXTURE_E" "$FIXTURE_E/.engram" "personal" $'\n'

assert_no_match "(e) no detection banner for the second instance" \
    "DETECTADA una instalación" "$OUT"
assert_eq "(e) Enter accepts the standard new directory for 'personal'" \
    "$FIXTURE_E/.local/share/engram-personal" "$ASKED_DIR"

rm -rf "$FIXTURE_E"

# ---------------------------------------------------------------------------
# (f) Counts unreadable -> detection and size are still reported; missing
#     figures are stated honestly, never fabricated. Two sub-cases:
#     sqlite3 unavailable, and a database sqlite3 cannot parse.
# ---------------------------------------------------------------------------
echo "== (f) unreadable counts -> honest, never fabricated =="

FIXTURE_F1="$(mktemp -d)"
mkdir -p "$FIXTURE_F1/.engram"
_make_fixture_db "$FIXTURE_F1/.engram/engram.db" 2 2

NOSQLITE_BIN="$(mktemp -d)"
for c in bash sqlite3-does-not-exist stat awk readlink dirname mkdir cat grep sed cut sha256sum mktemp rm; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    ln -sf "$p" "$NOSQLITE_BIN/$c"
done

run_ask_one_instance "$FIXTURE_F1" "" "work" $'\n~/.engram\n' "$NOSQLITE_BIN"

assert_match "(f1) still reports detection without sqlite3" \
    "DETECTADA una instalación de Engram existente" "$OUT"
assert_match "(f1) still reports a size" "MB" "$OUT"
assert_match "(f1) states the observation count honestly" \
    "no se pudo leer el número de observaciones" "$OUT"
assert_match "(f1) states the project count honestly" \
    "no se pudo leer el número de proyectos" "$OUT"
assert_no_match "(f1) never fabricates an observation count" "2 observaciones" "$OUT"
assert_no_match "(f1) never fabricates a project count" "2 proyectos" "$OUT"

rm -rf "$FIXTURE_F1" "$NOSQLITE_BIN"

FIXTURE_F2="$(mktemp -d)"
mkdir -p "$FIXTURE_F2/.engram"
printf 'not a real sqlite database file\n' > "$FIXTURE_F2/.engram/engram.db"

run_ask_one_instance "$FIXTURE_F2" "" "work" $'\n~/.engram\n'

assert_match "(f2) still reports detection for an unparseable db" \
    "DETECTADA una instalación de Engram existente" "$OUT"
assert_match "(f2) states the observation count honestly" \
    "no se pudo leer el número de observaciones" "$OUT"
assert_match "(f2) states the project count honestly" \
    "no se pudo leer el número de proyectos" "$OUT"

rm -rf "$FIXTURE_F2"

# ---------------------------------------------------------------------------
# (g) Exhausted input terminates instead of spinning. The no-default prompt
#     cannot fall back the way the default-offering branch does, so an EOF
#     read has to end the run: re-asking a stream that is already finished
#     consumes nothing and prints the refusal forever. Both a stream that
#     never held an answer and one exhausted after a rejected value are
#     covered, because the validation failure path re-enters the same loop.
# ---------------------------------------------------------------------------
echo "== (g) exhausted input terminates, never spins =="

FIXTURE_G="$(mktemp -d)"
mkdir -p "$FIXTURE_G/.engram"
printf 'x' > "$FIXTURE_G/.engram/engram.db"

run_ask_one_instance "$FIXTURE_G" "" "work" ""

assert_eq "(g1) empty stdin exits non-zero instead of hanging" "1" "$STATUS"
assert_match "(g1) says the input ran out" "Entrada agotada sin respuesta" "$OUT"
assert_no_match "(g1) does not repeat the refusal" \
    $'vacío aquí.*\n.*vacío aquí' "$OUT"

# A value that fails validation sends the loop back to read; the stream is
# empty from there on, which is exactly the state that used to spin.
printf 'blocker\n' > "$FIXTURE_G/occupied"
run_ask_one_instance "$FIXTURE_G" "" "work" $'~/occupied\n'

assert_eq "(g2) input exhausted after a rejected value exits non-zero" "1" "$STATUS"
assert_match "(g2) rejects the non-directory first" "no es una carpeta" "$OUT"
assert_match "(g2) then reports the exhausted input" "Entrada agotada sin respuesta" "$OUT"

rm -rf "$FIXTURE_G"

# ---------------------------------------------------------------------------
# Real $HOME was never read or written by any of the above.
# ---------------------------------------------------------------------------
echo "== real \$HOME isolation =="

AFTER_REAL_HOME="$(_real_snapshot)"
assert_eq "real \$HOME files unchanged by the whole test run" "$BEFORE_REAL_HOME" "$AFTER_REAL_HOME"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
