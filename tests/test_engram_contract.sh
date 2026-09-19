#!/usr/bin/env bash
#
# Checks the assumptions this tool makes about Engram, against the Engram that
# is actually installed. tests/test_router.sh covers our own logic with no
# Engram at all; this one covers the seam between us and it.
#
# Run it after upgrading Engram. Every failure here names a behaviour that was
# verified once and has changed since, which is the kind of breakage that
# otherwise shows up as a migration that quietly moved nothing.
#
# Sandboxed: every instance it creates lives in a temporary directory, and the
# real Engram binary is resolved directly so the shim cannot redirect it. It
# never reads or writes ~/.engram or any configured instance.
set -uo pipefail

PASS=0; FAIL=0
# assert_* rather than `cond && ok || bad`: in that form the failure branch
# also runs when the success branch returns non-zero, which is not what a test
# result should depend on.
_pass() { printf '  ok      %s\n' "$1"; PASS=$((PASS+1)); }
_fail() {
    printf '  FAILED  %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '            %s\n' "$2"
    FAIL=$((FAIL+1))
}

assert_eq() {  # label expected actual [hint]
    if [[ "$2" == "$3" ]]; then _pass "$1"
    else _fail "$1" "esperado '$2', obtenido '$3'${4:+ — $4}"; fi
}

assert_match() {  # label pattern text [hint]
    if grep -qE "$2" <<<"$3"; then _pass "$1"
    else _fail "$1" "no aparece /$2/${4:+ — $4}"; fi
}

# The shim marks itself; anything carrying that marker is not the real binary.
real_engram() {
    local entry candidate
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        candidate="$entry/engram"
        [[ -x "$candidate" ]] || continue
        grep -q 'engram-router-shim' "$candidate" 2>/dev/null && continue
        printf '%s' "$candidate"; return 0
    done < <(printf '%s' "${PATH:-}" | tr ':' '\n')
    return 1
}

ENGRAM="$(real_engram)" || { echo "no se encuentra el binario real de Engram"; exit 1; }
VERSION="$("$ENGRAM" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
VERIFIED="2.0.0"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Always environment-clean and always the real binary: a stray ENGRAM_CLOUD_*
# would make several of these assertions pass for the wrong reason.
E() {
    local dir="$1"; shift
    env -u ENGRAM_CLOUD_SERVER -u ENGRAM_CLOUD_TOKEN -u ENGRAM_CLOUD_AUTOSYNC \
        ENGRAM_DATA_DIR="$dir" "$ENGRAM" "$@" 2>&1
}

echo "Contrato con Engram $VERSION (verificado con $VERIFIED)"
[[ "$VERSION" == "$VERIFIED" ]] || echo "  AVISO: versión distinta de la verificada; los fallos de abajo son lo que ha cambiado"
echo

# --- 1. ENGRAM_DATA_DIR aísla instancias -----------------------------------
echo "== Aislamiento por data dir =="
A="$SANDBOX/a"; B="$SANDBOX/b"; mkdir -p "$A" "$B"
E "$A" save "sonda" "contenido" --project proyecto-sonda >/dev/null
a_rows="$(sqlite3 "$A/engram.db" "SELECT COUNT(*) FROM observations;" 2>/dev/null || echo err)"
b_rows="$(sqlite3 "$B/engram.db" "SELECT COUNT(*) FROM observations;" 2>/dev/null || echo 0)"
assert_eq "una escritura aterriza en su instancia" 1 "$a_rows"
assert_eq "la otra instancia no la ve" 0 "$b_rows"

# --- 2. cloud.json: clave y precedencia ------------------------------------
echo
echo "== Credenciales desde cloud.json =="
printf '{"server_url":"https://contrato-a.invalid","token":"t"}\n' > "$A/cloud.json"; chmod 600 "$A/cloud.json"
st="$(E "$A" cloud status)"
assert_match "'Server source:' sigue existiendo" '^Server source:' "$st" "engram-where y engram-doctor lo parsean"
assert_match "'Server:' sigue existiendo" '^Server:' "$st" "engram-migrate lo parsea"
assert_match "resuelve desde cloud.json con el entorno limpio" '^Server source:[[:space:]]*cloud\.json' "$st"
assert_match "la clave es 'server_url'" 'contrato-a\.invalid' "$st" "si cambió, install.sh escribe un cloud.json inservible"

polluted="$(ENGRAM_CLOUD_SERVER=https://otro.invalid ENGRAM_CLOUD_TOKEN=x ENGRAM_DATA_DIR="$A" "$ENGRAM" cloud status 2>&1)"
assert_match "el entorno sigue teniendo precedencia sobre cloud.json" \
    '^Server source:[[:space:]]*ENGRAM_CLOUD_SERVER' "$polluted" "la detección de contaminación asume esto"

# --- 3. El token exige HTTPS ------------------------------------------------
echo
echo "== El bearer token exige HTTPS =="
printf '{"server_url":"http://contrato-b.invalid","token":"t"}\n' > "$B/cloud.json"; chmod 600 "$B/cloud.json"
E "$B" cloud enroll proyecto-sonda >/dev/null 2>&1
push="$(E "$B" sync --cloud --project proyecto-sonda)"
assert_match "rechaza empujar por HTTP plano" 'HTTPS|https' "$push" "install.sh valida la URL basándose en esto"

# --- 4. Enrollment: local, por instancia, sin identidad de servidor ---------
echo
echo "== Enrollment =="
E "$A" cloud enroll proyecto-sonda >/dev/null 2>&1
a_enr="$(sqlite3 "$A/engram.db" "SELECT COUNT(*) FROM sync_enrolled_projects WHERE project='proyecto-sonda';" 2>/dev/null || echo err)"
assert_eq "enrolar escribe en sync_enrolled_projects" 1 "$a_enr"
cols="$(sqlite3 "$A/engram.db" "PRAGMA table_info(sync_enrolled_projects);" 2>/dev/null | cut -d'|' -f2 | paste -sd, )"
assert_eq "sigue sin columna de servidor" "project,enrolled_at" "$cols" "si ahora la tiene, esta herramienta puede sobrar"
E "$A" cloud unenroll proyecto-sonda >/dev/null 2>&1
a_unenr="$(sqlite3 "$A/engram.db" "SELECT COUNT(*) FROM sync_enrolled_projects WHERE project='proyecto-sonda';" 2>/dev/null || echo err)"
assert_eq "desenrolar lo retira" 0 "$a_unenr"

# --- 5. Export/import local: la base de la migración -----------------------
echo
echo "== Export e import entre instancias =="
REPO="$SANDBOX/proyecto-sonda"; mkdir -p "$REPO"
cd "$REPO" || { echo "no se puede entrar en $REPO"; exit 1; }
exp="$(E "$A" sync)"
assert_match "el export informa 'Observations:'" '^[[:space:]]*Observations:' "$exp" "engram-migrate lo parsea"
if [[ -d "$REPO/.engram/chunks" ]]; then _pass "escribe los chunks en .engram/chunks/"
else _fail "escribe los chunks en .engram/chunks/" "la migración depende de esta ruta"; fi
C="$SANDBOX/c"; mkdir -p "$C"
E "$C" sync --import >/dev/null
c_rows="$(sqlite3 "$C/engram.db" "SELECT COUNT(*) FROM observations WHERE LOWER(project)='proyecto-sonda';" 2>/dev/null || echo err)"
assert_eq "el import lleva las observaciones a otra instancia" 1 "$c_rows"
again="$(E "$C" sync --import)"
assert_match "reimportar dice 'No new chunks to import'" 'No new chunks to import' "$again" "así se reconoce una reejecución"
c_again="$(sqlite3 "$C/engram.db" "SELECT COUNT(*) FROM observations WHERE LOWER(project)='proyecto-sonda';" 2>/dev/null || echo err)"
assert_eq "el import es idempotente" 1 "$c_again"

# --- 6. Esquema del que dependen los conteos -------------------------------
echo
echo "== Esquema de observations =="
obs_cols="$(sqlite3 "$A/engram.db" "PRAGMA table_info(observations);" 2>/dev/null | cut -d'|' -f2 | paste -sd, )"
for col in project scope deleted_at; do
    assert_match "observations.$col existe" "(^|,)$col(,|$)" "$obs_cols" "engram-migrate cuenta con esta columna"
done

cd /
echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
