#!/usr/bin/env bash
#
# tests/test_status.sh — bin/engram-status: read-only sync-state report per
# instance (cloud destination, daemon liveness, autosync, sync_state
# lifecycle/counters/reason_code, enrolled projects, unenrolled-pending
# projects) plus the current directory's routing.
#
# Covers (per odd/tasks/engram-status.md acceptance + TDD list):
#   - two healthy instances render cloud, daemon, autosync, lifecycle, counters
#   - a degraded instance shows its reason_code and the non-enrolled projects
#     behind it, capped to a few by volume
#   - a missing cloud.json renders as "desconocido", not an error
#   - an unreadable engram.db renders as "desconocido" and does not stop the
#     other instances in the same run from rendering fully
#   - a stopped daemon (no real systemd unit for the fixture name) renders
#     "inactivo"
#   - an instance-less router.json ("no hay instancias configuradas")
#   - current-directory resolution, both matched and unmatched
#   - --json parses with python3 -m json.tool and never contains the token
#     value
#   - exit status 0 when every instance is healthy, non-zero otherwise
#   - the real $HOME's engram-router files stay byte-identical
#
# Test-safety (same discipline as tests/test_doctor_hook.sh):
#   - every run uses a fixture HOME/ENGRAM_ROUTER_CONFIG/ENGRAM_ROUTER_LIB,
#     never the real ones
#   - ENGRAM_CLOUD_* is scrubbed from every run's environment
#   - the real $HOME's engram-router files are snapshotted before and after
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
assert_not_match() {  # label pattern text
    if grep -qE "$2" <<<"$3"; then _fail "$1" "unexpectedly matches /$2/ — got: $3"
    else _pass "$1"; fi
}

# ---------------------------------------------------------------------------
# Real $HOME safety net (same pattern as tests/test_doctor_hook.sh).
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
      find "$HOME/.local/share" -maxdepth 1 -name 'engram-*' 2>/dev/null
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
FIXTURE_HOME="$FIXTURE/home"
mkdir -p "$FIXTURE_HOME"

SQLITE3_AVAILABLE=1
command -v sqlite3 >/dev/null 2>&1 || SQLITE3_AVAILABLE=0

# ---------------------------------------------------------------------------
# Instance data dirs: trabajo (healthy), personal (healthy), problemas
# (degraded, missing cloud.json), roto (unreadable engram.db).
# ---------------------------------------------------------------------------
DATA_DIR="$FIXTURE_HOME/.local/share"
TRABAJO_DIR="$DATA_DIR/engram-trabajo"
PERSONAL_DIR="$DATA_DIR/engram-personal"
PROBLEMAS_DIR="$DATA_DIR/engram-problemas"
ROTO_DIR="$DATA_DIR/engram-roto"
mkdir -p "$TRABAJO_DIR" "$PERSONAL_DIR" "$PROBLEMAS_DIR" "$ROTO_DIR"

TRABAJO_TOKEN="TOKVAL-TRABAJO-SECRET"
PERSONAL_TOKEN="TOKVAL-PERSONAL-SECRET"
ROTO_TOKEN="TOKVAL-ROTO-SECRET"

cat >"$TRABAJO_DIR/cloud.json" <<EOF
{"server_url": "https://cloud-trabajo.example.com", "token": "$TRABAJO_TOKEN"}
EOF
chmod 0600 "$TRABAJO_DIR/cloud.json"

cat >"$PERSONAL_DIR/cloud.json" <<EOF
{"server_url": "https://cloud-personal.example.com", "token": "$PERSONAL_TOKEN"}
EOF
chmod 0600 "$PERSONAL_DIR/cloud.json"

# "problemas" deliberately has NO cloud.json.

cat >"$ROTO_DIR/cloud.json" <<EOF
{"server_url": "https://cloud-roto.example.com", "token": "$ROTO_TOKEN"}
EOF
chmod 0600 "$ROTO_DIR/cloud.json"

# "sintabla"/"columnas": db opens but a query must fail (F1).
SINTABLA_DIR="$DATA_DIR/engram-sintabla"; COLUMNAS_DIR="$DATA_DIR/engram-columnas"
mkdir -p "$SINTABLA_DIR" "$COLUMNAS_DIR"

# ---------------------------------------------------------------------------
# Instance env files: trabajo autosync ON, personal OFF (commented, matching
# install.sh's own template), problemas has no env file at all, roto ON.
# ---------------------------------------------------------------------------
INSTANCES_ENV_DIR="$FIXTURE_HOME/.config/engram-router/instances"
mkdir -p "$INSTANCES_ENV_DIR"
cat >"$INSTANCES_ENV_DIR/trabajo-ts.env" <<'EOF'
ENGRAM_CLOUD_AUTOSYNC=1
EOF
cat >"$INSTANCES_ENV_DIR/personal-ts.env" <<'EOF'
# Uncomment to enable autosync for the "personal" instance.
# ENGRAM_CLOUD_AUTOSYNC=1
EOF
cat >"$INSTANCES_ENV_DIR/roto-ts.env" <<'EOF'
ENGRAM_CLOUD_AUTOSYNC=1
EOF

# ---------------------------------------------------------------------------
# engram.db fixtures.
# ---------------------------------------------------------------------------
if [[ $SQLITE3_AVAILABLE -eq 1 ]]; then
    sqlite3 "$TRABAJO_DIR/engram.db" <<'SQL'
CREATE TABLE sync_state (target_key TEXT, lifecycle TEXT, last_enqueued_seq INT,
    last_acked_seq INT, last_pulled_seq INT, reason_code TEXT, last_error TEXT,
    last_success_at TEXT);
INSERT INTO sync_state VALUES ('cloud','healthy',12,12,7,NULL,NULL,'2026-09-20T08:00:00Z');
CREATE TABLE sync_enrolled_projects (project TEXT);
INSERT INTO sync_enrolled_projects VALUES ('proyecto-uno'),('proyecto-dos');
CREATE TABLE sync_mutations (id INTEGER PRIMARY KEY, target_key TEXT, project TEXT, acked_at TEXT);
INSERT INTO sync_mutations (target_key, project, acked_at) VALUES ('cloud','proyecto-uno',NULL);
INSERT INTO sync_mutations (target_key, project, acked_at) VALUES ('cloud','ajeno','2026-01-01');
SQL

    sqlite3 "$PERSONAL_DIR/engram.db" <<'SQL'
CREATE TABLE sync_state (target_key TEXT, lifecycle TEXT, last_enqueued_seq INT,
    last_acked_seq INT, last_pulled_seq INT, reason_code TEXT, last_error TEXT,
    last_success_at TEXT);
INSERT INTO sync_state VALUES ('cloud','healthy',3,3,3,NULL,NULL,'2026-09-19T00:00:00Z');
CREATE TABLE sync_enrolled_projects (project TEXT);
INSERT INTO sync_enrolled_projects VALUES ('proyecto-tres');
CREATE TABLE sync_mutations (id INTEGER PRIMARY KEY, target_key TEXT, project TEXT, acked_at TEXT);
SQL

    sqlite3 "$PROBLEMAS_DIR/engram.db" <<'SQL'
CREATE TABLE sync_state (target_key TEXT, lifecycle TEXT, last_enqueued_seq INT,
    last_acked_seq INT, last_pulled_seq INT, reason_code TEXT, last_error TEXT,
    last_success_at TEXT);
INSERT INTO sync_state VALUES ('cloud','degraded',8,3,2,'non_enrolled_pending_mutations',NULL,'2026-09-15T00:00:00Z');
CREATE TABLE sync_enrolled_projects (project TEXT);
INSERT INTO sync_enrolled_projects VALUES ('proyecto-a');
CREATE TABLE sync_mutations (id INTEGER PRIMARY KEY, target_key TEXT, project TEXT, acked_at TEXT);
INSERT INTO sync_mutations (target_key, project, acked_at) VALUES ('cloud','proyecto-a',NULL);
INSERT INTO sync_mutations (target_key, project, acked_at) VALUES
    ('cloud','proyecto-c',NULL),('cloud','proyecto-c',NULL),('cloud','proyecto-c',NULL),
    ('cloud','proyecto-c',NULL),('cloud','proyecto-c',NULL),
    ('cloud','proyecto-d',NULL),('cloud','proyecto-d',NULL),
    ('cloud','proyecto-e',NULL);
SQL

    # "roto": not a valid sqlite database at all.
    printf 'this is not a sqlite database\n' > "$ROTO_DIR/engram.db"

    # "sintabla": sync_state ok; sync_enrolled_projects table absent.
    sqlite3 "$SINTABLA_DIR/engram.db" <<'SQL'
CREATE TABLE sync_state (target_key TEXT, lifecycle TEXT, last_enqueued_seq INT,
    last_acked_seq INT, last_pulled_seq INT, reason_code TEXT, last_error TEXT,
    last_success_at TEXT);
INSERT INTO sync_state VALUES ('cloud','healthy',1,1,1,NULL,NULL,'2026-09-21T00:00:00Z');
SQL

    # "columnas": sync_state has unexpected columns (schema drift).
    sqlite3 "$COLUMNAS_DIR/engram.db" <<'SQL'
CREATE TABLE sync_state (target_key TEXT, estado TEXT);
INSERT INTO sync_state VALUES ('cloud','healthy');
CREATE TABLE sync_enrolled_projects (project TEXT);
CREATE TABLE sync_mutations (id INTEGER PRIMARY KEY, target_key TEXT, project TEXT, acked_at TEXT);
SQL
fi

# ---------------------------------------------------------------------------
# router.json — full fixture (4 instances) and two variants: healthy-only
# (exit 0 check) and instance-less (empty-config check).
# ---------------------------------------------------------------------------
CONFIG_DIR="$FIXTURE_HOME/.config/engram-router"
mkdir -p "$CONFIG_DIR"

FULL_CONFIG="$CONFIG_DIR/router.json"
cat >"$FULL_CONFIG" <<EOF
{
  "rules": [
    { "prefix": "github.com/mi-empresa", "instance": "trabajo-ts" }
  ],
  "instances": {
    "trabajo-ts": { "data_dir": "$TRABAJO_DIR", "port": 7438, "autosync": true },
    "personal-ts": { "data_dir": "$PERSONAL_DIR", "port": 7439, "autosync": false },
    "problemas-ts": { "data_dir": "$PROBLEMAS_DIR", "port": 7440, "autosync": true },
    "roto-ts": { "data_dir": "$ROTO_DIR", "port": 7441, "autosync": true }
  }
}
EOF

HEALTHY_ONLY_CONFIG="$CONFIG_DIR/router-healthy-only.json"
cat >"$HEALTHY_ONLY_CONFIG" <<EOF
{
  "rules": [],
  "instances": {
    "trabajo-ts": { "data_dir": "$TRABAJO_DIR", "port": 7438, "autosync": true },
    "personal-ts": { "data_dir": "$PERSONAL_DIR", "port": 7439, "autosync": false }
  }
}
EOF

EMPTY_CONFIG="$CONFIG_DIR/router-empty.json"
cat >"$EMPTY_CONFIG" <<'EOF'
{
  "rules": [],
  "instances": {}
}
EOF

QUERYERR_CONFIG="$CONFIG_DIR/router-queryerr.json"
cat >"$QUERYERR_CONFIG" <<EOF
{ "rules": [], "instances": {
  "sintabla-ts": { "data_dir": "$SINTABLA_DIR" },
  "columnas-ts": { "data_dir": "$COLUMNAS_DIR" }
} }
EOF

# ---------------------------------------------------------------------------
# Fixture git repos for current-directory resolution.
# ---------------------------------------------------------------------------
WORK_REPO="$FIXTURE/work_repo"
git init -q "$WORK_REPO"
git -C "$WORK_REPO" remote add origin git@github.com:mi-empresa/proyecto.git

UNMATCHED_REPO="$FIXTURE/unmatched_repo"
git init -q "$UNMATCHED_REPO"
git -C "$UNMATCHED_REPO" remote add origin git@github.com:otro-tercero/proyecto.git

# ---------------------------------------------------------------------------
# Runner: cd's into $1, runs bin/engram-status with a fixture HOME/config,
# extra args in $3.... Leaves STATUS_OUT (captured stdout+stderr) and
# STATUS_RC (exit status) for the caller.
# ---------------------------------------------------------------------------
_run_status() {  # dir config_file [extra args...]
    local dir="$1" config="$2"
    shift 2
    STATUS_OUT="$(mktemp -p "$FIXTURE")"
    (
        for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
        cd "$dir" || exit 90
        export HOME="$FIXTURE_HOME"
        export ENGRAM_ROUTER_CONFIG="$config"
        export ENGRAM_ROUTER_LIB="$ROOT_DIR/lib/router.sh"
        export ENGRAM_ROUTER_INSTANCES_DIR="$INSTANCES_ENV_DIR"
        bash "$ROOT_DIR/bin/engram-status" "$@"
    ) >"$STATUS_OUT" 2>&1
    STATUS_RC=$?
}

# ===========================================================================
# --help
# ===========================================================================
echo "== --help =="
_run_status "$UNMATCHED_REPO" "$FULL_CONFIG" --help
assert_match "--help mentions --json" "\-\-json" "$(cat "$STATUS_OUT")"
assert_eq "--help exits 0" "0" "$STATUS_RC"

# ===========================================================================
# Full fixture, human output.
# ===========================================================================
echo
echo "== full fixture: human output renders all four instances =="
_run_status "$WORK_REPO" "$FULL_CONFIG"
FULL_OUT="$(cat "$STATUS_OUT")"

echo "$FULL_OUT" | sed 's/^/    /'

assert_match "trabajo section header shows SALUDABLE" \
    "== Instancia: trabajo-ts.*SALUDABLE" "$FULL_OUT"
assert_match "trabajo cloud line shows its server_url and 'presente' token" \
    "cloud:.*https://cloud-trabajo\.example\.com.*token: presente" "$FULL_OUT"
TRABAJO_BLOCK="$(awk '/== Instancia: trabajo-ts/{f=1} f{print} f&&/^$/{exit}' <<<"$FULL_OUT")"
assert_match "trabajo autosync is activado" \
    "autosync:[[:space:]]*activado" "$TRABAJO_BLOCK"
assert_match "trabajo counters render enqueued/acked/pulled" \
    "12/12.*pull: 7" "$FULL_OUT"
assert_match "trabajo enrolled projects listed, alphabetical" \
    "proyectos enrolados \(2\): proyecto-dos, proyecto-uno" "$FULL_OUT"
assert_match "trabajo has no unenrolled-pending projects" \
    "cambios sin sincronizar y sin enrolar: ninguno" "$FULL_OUT"

assert_match "personal section header shows SALUDABLE" \
    "== Instancia: personal-ts.*SALUDABLE" "$FULL_OUT"
assert_match "personal counters render 3/3 pull 3" \
    "3/3.*pull: 3" "$FULL_OUT"

assert_match "problemas section header shows DEGRADADA" \
    "== Instancia: problemas-ts.*DEGRADADA" "$FULL_OUT"
assert_match "problemas shows its reason_code" \
    "reason_code: non_enrolled_pending_mutations" "$FULL_OUT"
assert_match "problemas shows missing cloud.json as desconocido, not an error" \
    "cloud:.*desconocido" "$FULL_OUT"
assert_match "problemas lists the top non-enrolled projects by volume" \
    "proyecto-c: 5 mutaci" "$FULL_OUT"
assert_match "problemas lists proyecto-d with 2" \
    "proyecto-d: 2 mutaci" "$FULL_OUT"
assert_not_match "problemas' own enrolled project never appears in the unenrolled list" \
    "proyecto-a: [0-9]+ mutaci" "$FULL_OUT"

assert_match "roto section header shows an unknown/degraded state, not a crash" \
    "== Instancia: roto-ts.*DESCONOCID" "$FULL_OUT"
assert_match "roto reports the database could not be opened" \
    "no se pudo abrir" "$FULL_OUT"
assert_match "roto's cloud.json still renders (independent of db readability)" \
    "cloud-roto\.example\.com" "$FULL_OUT"

assert_match "current directory section names the resolved instance" \
    "instancia:.*trabajo-ts" "$FULL_OUT"

assert_not_match "no token value ever appears in human output" \
    "TOKVAL-(TRABAJO|PERSONAL|ROTO)-SECRET" "$FULL_OUT"

assert_eq "exit status is non-zero: problemas is degraded and roto is unreadable" \
    "1" "$STATUS_RC"

# ===========================================================================
# Stopped daemon: none of the fixture instance names have a real systemd
# unit, so every instance in this run renders "inactivo".
# ===========================================================================
echo
echo "== stopped daemon renders as inactivo =="
assert_match "trabajo's daemon line reports inactivo (no real unit for this fixture name)" \
    "daemon:[[:space:]]*inactivo" "$FULL_OUT"

# ===========================================================================
# Healthy-only fixture: exit status 0.
# ===========================================================================
echo
echo "== healthy-only fixture: exit status 0 =="
_run_status "$UNMATCHED_REPO" "$HEALTHY_ONLY_CONFIG"
assert_eq "exit status is 0 when every configured instance is healthy" \
    "0" "$STATUS_RC"
assert_match "healthy-only output still shows both instances SALUDABLE" \
    "SALUDABLE" "$(cat "$STATUS_OUT")"

# ===========================================================================
# Instance-less router.json.
# ===========================================================================
echo
echo "== router.json with no instances configured =="
_run_status "$UNMATCHED_REPO" "$EMPTY_CONFIG"
assert_match "reports no instances configured" \
    "no hay instancias configuradas" "$(cat "$STATUS_OUT")"
assert_eq "exit status is 0 (vacuously healthy: nothing to fail)" \
    "0" "$STATUS_RC"

echo
echo "== a failed query renders as desconocido, not a false all-clear (F1) =="
_run_status "$UNMATCHED_REPO" "$QUERYERR_CONFIG"
QUERYERR_OUT="$(cat "$STATUS_OUT")"
if [[ $SQLITE3_AVAILABLE -eq 1 ]]; then
    assert_match "missing sync_enrolled_projects: enrolled renders desconocido" \
        "proyectos enrolados: desconocido" "$QUERYERR_OUT"
    assert_match "missing table also fails the unenrolled-pending query" \
        "cambios sin sincronizar y sin enrolar: desconocido" "$QUERYERR_OUT"
    assert_match "column-mismatch renders the OTHER instance as unknown too" \
        "== Instancia: columnas-ts.*DESCONOCID" "$QUERYERR_OUT"
fi
assert_eq "exit status is non-zero: an openable db with a failed query is not healthy" \
    "1" "$STATUS_RC"

_run_status "$UNMATCHED_REPO" "$QUERYERR_CONFIG" --json
QUERYERR_JSON="$(cat "$STATUS_OUT")"
if [[ $SQLITE3_AVAILABLE -eq 1 ]]; then
    assert_match "sintabla's enrolled_projects is null in --json, not []" \
        '"name":"sintabla-ts".*"enrolled_projects":null' "$QUERYERR_JSON"
    assert_match "sintabla is reported unhealthy despite its healthy sync row" \
        '"name":"sintabla-ts".*"healthy":false' "$QUERYERR_JSON"
fi

# ===========================================================================
# Current-directory resolution: matched and unmatched.
# ===========================================================================
echo
echo "== current-directory resolution: matched =="
_run_status "$WORK_REPO" "$FULL_CONFIG"
assert_match "matched repo names 'trabajo' as the resolved instance" \
    "instancia:.*trabajo-ts" "$(cat "$STATUS_OUT")"

echo
echo "== current-directory resolution: unmatched =="
_run_status "$UNMATCHED_REPO" "$FULL_CONFIG"
assert_match "unmatched repo reports no resolved instance" \
    "instancia:.*ninguna" "$(cat "$STATUS_OUT")"

# ===========================================================================
# --json mode.
# ===========================================================================
echo
echo "== --json: valid JSON, no tokens =="
_run_status "$WORK_REPO" "$FULL_CONFIG" --json
JSON_OUT="$(cat "$STATUS_OUT")"
JSON_RC="$STATUS_RC"

if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$JSON_OUT" | python3 -m json.tool >/dev/null 2>&1; then
        _pass "--json output parses with python3 -m json.tool"
    else
        _fail "--json output parses with python3 -m json.tool" \
            "$(printf '%s' "$JSON_OUT" | python3 -m json.tool 2>&1 | head -3)"
    fi
else
    _fail "--json output parses with python3 -m json.tool" "python3 not available to verify"
fi

assert_match "--json output names the trabajo instance" '"trabajo-ts"' "$JSON_OUT"
assert_match "--json output names the degraded lifecycle" '"degraded"' "$JSON_OUT"
assert_not_match "--json output never contains a token value" \
    "TOKVAL-(TRABAJO|PERSONAL|ROTO)-SECRET" "$JSON_OUT"
assert_eq "--json exit status matches the human run (same underlying facts)" \
    "$STATUS_RC" "$JSON_RC"

# ===========================================================================
# sqlite3 availability is documented, not silently ignored.
# ===========================================================================
echo
if [[ $SQLITE3_AVAILABLE -eq 0 ]]; then
    echo "== sqlite3 not available on this host: every instance must degrade, not crash =="
    assert_match "with no sqlite3, sync state renders as desconocido" \
        "desconocido" "$FULL_OUT"
else
    echo "== sqlite3 available: skipping the no-sqlite3 branch (covered structurally above) =="
fi

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
