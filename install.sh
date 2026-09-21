#!/usr/bin/env bash
# install.sh — interactive installer for the Engram multi-cloud router.
#
# All user-facing output is in Spanish (neutral, professional), per the
# language contract. Code/comments stay in English.
#
# Safe to re-run (idempotent): existing cloud.json / router.json content is
# never silently overwritten, and no dotfile is ever edited automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX_BIN="${ENGRAM_ROUTER_BIN:-$HOME/.local/bin}"
LIB_DIR="${ENGRAM_ROUTER_LIB_DIR:-$HOME/.local/lib/engram-router}"
CONFIG_DIR="${ENGRAM_ROUTER_CONFIG_DIR:-$HOME/.config/engram-router}"
CONFIG_FILE="$CONFIG_DIR/router.json"
INSTANCES_ENV_DIR="$CONFIG_DIR/instances"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

DOTFILES_TO_SCAN=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.zshrc"
    "$HOME/.zprofile"
)

say() { printf '%s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# Remediation helpers for detect_hazardous_exports() below. Every command
# they print is built from what this run actually detected — real file
# paths, real variable names, real PIDs — never a placeholder.
# ---------------------------------------------------------------------------

# _hazard_variable_names FILE_HITS_ARRAY_NAME ENV_HITS_ARRAY_NAME
# Prints the union of ENGRAM_CLOUD_* variable names found in the scanned
# files and already exported into this session, deduplicated and sorted.
# This is what feeds the `systemctl --user unset-environment` command: the
# manager can hold a variable that came from a file even when it is not
# exported in *this* shell, so both sources are combined.
_hazard_variable_names() {
    local -n _files="$1"
    local -n _envs="$2"
    local -A hazard_names=()
    local var f name
    for var in "${_envs[@]}"; do
        hazard_names["$var"]=1
    done
    for f in "${_files[@]}"; do
        [[ -r "$f" ]] || continue
        while IFS= read -r name; do
            [[ -n "$name" ]] && hazard_names["$name"]=1
        done < <(grep -oE 'ENGRAM_CLOUD_[A-Za-z0-9_]*' "$f" 2>/dev/null)
    done
    printf '%s\n' "${!hazard_names[@]}" | sort
}

# _engram_serve_pids
# Prints the PID of every running "engram serve" process, one per line.
# The pattern is word-bounded so it never matches an unrelated subcommand
# such as "engram mcp ...". Returns 1 (prints nothing) when none is running.
_engram_serve_pids() {
    local out
    if command -v pgrep >/dev/null 2>&1; then
        out="$(pgrep -f 'engram serve([[:space:]]|$)' 2>/dev/null)" || true
    else
        # shellcheck disable=SC2009 # pgrep is unavailable in this branch; ps+grep is the fallback.
        out="$(ps -eo pid=,args= 2>/dev/null \
            | grep -E 'engram serve([[:space:]]|$)' \
            | awk '{print $1}')" || true
    fi
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# _print_comment_lines_step STEP_VAR FILE...
# Step: comment the ENGRAM_CLOUD_* lines out of each detected file, with a
# copy-pasteable `sed -i.bak` per file. sed's backup keeps the file's
# original mode (commonly 0644, world-readable) and it still holds the
# token, so the matching `chmod 600` is printed right after it, never
# separately — creating a stray world-readable copy of a credential while
# removing one is exactly the defect class this installer exists to catch.
_print_comment_lines_step() {
    local -n _step="$1"
    shift
    printf '  %d. Comente (no borre) las líneas ENGRAM_CLOUD_* en cada fichero\n' "$_step"
    # shellcheck disable=SC2016 # literal backticks in user-facing prose, not variable expansion.
    printf '     detectado. `sed -i.bak` deja una copia .bak con el mismo permiso\n'
    printf '     que el original (a menudo legible por cualquiera) y esa copia\n'
    printf '     sigue conteniendo el token, así que el chmod de abajo es parte\n'
    printf '     del mismo paso, no un extra:\n\n'
    local f qf qbak line
    for f in "$@"; do
        qf="$(printf '%q' "$f")"
        qbak="$(printf '%q' "${f}.bak")"
        line="       sed -i.bak -E 's/^([[:space:]]*(export[[:space:]]+)?ENGRAM_CLOUD_)/# \\1/' $qf"
        printf '%s\n' "$line"
        printf '       chmod 600 %s\n' "$qbak"
    done
    printf '\n     Si hay uno bajo ~/.config/environment.d/, es entorno de sesión de\n'
    printf '     systemd y lo hereda todo proceso de la sesión, no solo las shells.\n\n'
    _step=$(( _step + 1 ))
}

# _print_unset_environment_step STEP_VAR VARNAME...
# Step: clear the systemd --user manager with the exact detected names.
# Measured on systemd 255 (255.4-1ubuntu8.17): `unset-environment` removes
# variables the manager is holding regardless of who set them, and a fresh
# unit started afterwards no longer inherits them. It does not reach a
# process that is already running, because that process froze its
# environment at exec — that is what the next step (when applicable) and
# the clean-shell step below are for.
_print_unset_environment_step() {
    local -n _step="$1"
    shift
    printf '  %d. Limpie el gestor de systemd --user con los nombres detectados:\n' "$_step"
    printf '       systemctl --user unset-environment %s\n' "$*"
    printf '     Esto limpia el gestor y toda unidad que arranque después. NO toca\n'
    printf '     los procesos que ya están en marcha: cada uno fijó su entorno al\n'
    printf '     arrancar (exec).\n\n'
    _step=$(( _step + 1 ))
}

# _print_daemon_restart_step_if_needed STEP_VAR
# Step: only printed when an "engram serve" process is actually running.
# That process is exactly the kind the step above cannot reach — it froze
# the polluted environment at exec — so it has to be restarted separately.
_print_daemon_restart_step_if_needed() {
    local -n _step="$1"
    local pids
    pids="$(_engram_serve_pids)" || return 0
    printf '  %d. Reinicie el demonio Engram en marcha (PID %s): arrancó con el\n' \
        "$_step" "$(tr '\n' ',' <<<"$pids" | sed 's/,$//; s/,/, /g')"
    printf '     entorno contaminado y lo mantiene fijado aunque limpie el gestor de\n'
    printf '     arriba; solo reiniciar el propio proceso lo libera. Si lo gestiona\n'
    printf '     systemd --user, reinicie su unidad; si lo inició a mano, deténgalo\n'
    printf '     y vuelva a lanzarlo.\n\n'
    _step=$(( _step + 1 ))
}

# _print_clean_shell_step STEP_VAR
# Step: the current shell, and anything already started from it, still
# carries the exported variables no matter what the steps above did. A
# shell started fresh from a clean parent is clean once the files are
# commented; logging out is the guaranteed way when the desktop session
# itself carries them.
_print_clean_shell_step() {
    local -n _step="$1"
    printf '  %d. Su shell actual sigue teniendo las variables exportadas, igual\n' "$_step"
    printf '     que cualquier proceso ya arrancado desde ella. Abra una shell\n'
    printf '     nueva desde un padre limpio, o cierre sesión y vuelva a entrar si\n'
    printf '     el propio entorno de la sesión de escritorio las lleva: es la vía\n'
    printf '     garantizada.\n'
    printf '     Compruebe con: env | grep ENGRAM_CLOUD   (no debe salir nada)\n\n'
    _step=$(( _step + 1 ))
}

# ---------------------------------------------------------------------------
# Step 1 — preflight: detect the ENGRAM_CLOUD_* hazard. Never edit these
# files; if found, stop and explain, exactly as the feature spec requires.
# ---------------------------------------------------------------------------
detect_hazardous_exports() {
    section "Comprobación previa: variables ENGRAM_CLOUD_*"

    # Environment and files are reported separately because the remedy differs.
    # Variables only in the environment mean the files are already clean and the
    # session is stale: editing nothing and re-logging in is the whole fix.
    local hazard=0
    local env_hits=() file_hits=()

    local var
    for var in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do
        env_hits+=("$var")
        hazard=1
    done

    local f
    for f in "${DOTFILES_TO_SCAN[@]}"; do
        [[ -r "$f" ]] || continue
        if grep -qE '^\s*(export\s+)?ENGRAM_CLOUD_' "$f" 2>/dev/null; then
            file_hits+=("$f")
            hazard=1
        fi
    done
    for f in "$HOME"/.config/environment.d/*.conf; do
        [[ -e "$f" ]] || continue
        if grep -qE '^\s*ENGRAM_CLOUD_' "$f" 2>/dev/null; then
            file_hits+=("$f")
            hazard=1
        fi
    done

    if [[ $hazard -eq 1 ]]; then
        cat <<EOF

Se han detectado variables ENGRAM_CLOUD_* que anularían el enrutamiento
por cloud.json: con ellas presentes, Engram usa ENGRAM_CLOUD_SERVER en vez
de leer cloud.json, silenciosamente.

EOF
        if [[ ${#file_hits[@]} -gt 0 ]]; then
            printf 'Ficheros que las definen:\n'
            printf '  - %s\n' "${file_hits[@]}"
            printf '\n'
        fi
        if [[ ${#env_hits[@]} -gt 0 ]]; then
            printf 'Presentes en el entorno de esta sesión:\n'
            printf '  - %s\n' "${env_hits[@]}"
            printf '\n'
        fi

        printf 'Esta instalación NO va a editar automáticamente ningún dotfile.\n\n'

        local -a var_names=()
        while IFS= read -r _vn; do
            [[ -n "$_vn" ]] && var_names+=("$_vn")
        done < <(_hazard_variable_names file_hits env_hits)

        local step=1
        if [[ ${#file_hits[@]} -eq 0 ]]; then
            printf 'Los ficheros ya están limpios: solo queda contaminación de sesión\n'
            printf '(entorno vivo y, si las heredó de ahí, el gestor de systemd --user).\n\n'
            _print_unset_environment_step step "${var_names[@]}"
            _print_daemon_restart_step_if_needed step
            _print_clean_shell_step step
            printf '  %d. Vuelva a ejecutar este instalador.\n' "$step"
        else
            _warn_token_loss_if_needed
            printf 'Cómo resolverlo antes de reintentar:\n\n'
            _print_comment_lines_step step "${file_hits[@]}"
            _print_unset_environment_step step "${var_names[@]}"
            _print_daemon_restart_step_if_needed step
            _print_clean_shell_step step
            printf '  %d. Vuelva a ejecutar este instalador.\n' "$step"
        fi
        printf '\n'
        cat <<EOF
Instalación detenida.
EOF
        exit 1
    fi
    say "OK: no se han encontrado exportaciones ENGRAM_CLOUD_* peligrosas."
}

# ---------------------------------------------------------------------------
# Step 1a — token-survival check: only reached from the "files present"
# remediation branch above, whose step 1 tells the user to delete the
# ENGRAM_CLOUD_* lines. If ENGRAM_CLOUD_TOKEN is live in this session and no
# other non-empty copy exists (~/.engram/cloud.json or an already-provisioned
# instance's cloud.json), following that instruction destroys the credential
# irrecoverably. This check never writes anything and never prints the token
# value itself — only locations.
# ---------------------------------------------------------------------------

# _cloud_json_token CLOUD_JSON_PATH
# Prints the "token" field of a flat cloud.json (same shape read by
# bin/engram-router::_instance_cloud_server), or fails if the file is
# unreadable, malformed, or the field is empty.
_cloud_json_token() {
    local cloud_json="$1" content
    [[ -r "$cloud_json" ]] || return 1
    content="$(cat "$cloud_json" 2>/dev/null)" || return 1
    local -A obj=()
    _router_json_parse_flat_object "$content" 0 obj 2>/dev/null || return 1
    local token="${obj[token]:-}"
    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

# _classify_token_copy CLOUD_JSON_PATH [SUFFIX]
# Classifies one cloud.json against the token that is live in this session.
# Presence of *a* token is not enough: a copy only survives the remediation
# if it holds the SAME value. A different non-empty token — rotated, revoked,
# or belonging to another server — leaves the live credential exactly as
# unrecoverable, so it is reported as OTHER and never counted as a survivor.
# Reassuring the user on presence alone would turn this warning fail-open.
_classify_token_copy() {
    local cloud_json="$1" suffix="${2:-}" stored
    if [[ ! -e "$cloud_json" ]]; then
        printf 'MISSING:%s%s\n' "$cloud_json" "$suffix"
        return 0
    fi
    if ! stored="$(_cloud_json_token "$cloud_json" 2>/dev/null)"; then
        printf 'EMPTY:%s%s\n' "$cloud_json" "$suffix"
        return 0
    fi
    if [[ "$stored" == "${ENGRAM_CLOUD_TOKEN:-}" ]]; then
        printf 'SURVIVING:%s%s\n' "$cloud_json" "$suffix"
    else
        printf 'OTHER:%s%s\n' "$cloud_json" "$suffix"
    fi
}

# _load_router_lib_best_effort
# Sources lib/router.sh (installed copy first, repo copy as fallback — same
# pattern as load_existing_config) so _router_json_parse_flat_object and
# router_expand_path are available. Never fatal: callers degrade gracefully
# when neither copy can be sourced.
_load_router_lib_best_effort() {
    # shellcheck source=lib/router.sh
    source "$LIB_DIR/router.sh" 2>/dev/null && return 0
    # shellcheck source=lib/router.sh
    source "$SCRIPT_DIR/lib/router.sh" 2>/dev/null && return 0
    return 1
}

# _token_definition_locations
# Prints "file:line" for each line that defines ENGRAM_CLOUD_TOKEN
# specifically, across the same files the hazard scan above already reads.
_token_definition_locations() {
    local f
    for f in "${DOTFILES_TO_SCAN[@]}"; do
        [[ -r "$f" ]] || continue
        # "|| true": grep exits 1 on no match, which under pipefail would
        # otherwise abort this loop early (set -e) and skip the remaining
        # files instead of just reporting an empty result for this one.
        grep -nE '^\s*(export\s+)?ENGRAM_CLOUD_TOKEN=' "$f" 2>/dev/null \
            | while IFS=: read -r lineno _; do printf '%s:%s\n' "$f" "$lineno"; done || true
    done
    for f in "$HOME"/.config/environment.d/*.conf; do
        [[ -e "$f" ]] || continue
        grep -nE '^\s*ENGRAM_CLOUD_TOKEN=' "$f" 2>/dev/null \
            | while IFS=: read -r lineno _; do printf '%s:%s\n' "$f" "$lineno"; done || true
    done
}

# _survey_token_copies
# Checks $HOME/.engram/cloud.json and every already-provisioned instance's
# cloud.json (per router.json, if any) for a non-empty token. Prints one
# line per location actually checked, prefixed SURVIVING:, EMPTY:, or
# MISSING:, so the caller can report exactly what it found — never a guess.
_survey_token_copies() {
    # Loaded once, up front: _cloud_json_token below needs
    # _router_json_parse_flat_object regardless of which path it checks, and
    # this runs before install_files ever puts a copy of the library in
    # place, so the repo copy is very often the only one available yet.
    _load_router_lib_best_effort || true

    _classify_token_copy "$HOME/.engram/cloud.json"

    [[ -r "$CONFIG_FILE" ]] || return 0
    _load_router_lib_best_effort || return 0
    declare -f router_load_config >/dev/null 2>&1 || return 0
    router_load_config "$CONFIG_FILE" 2>/dev/null || return 0
    [[ ${#INSTANCE_NAMES[@]} -gt 0 ]] || return 0

    local name data_dir icj
    for name in "${INSTANCE_NAMES[@]}"; do
        data_dir="$(router_expand_path "${INSTANCE_DATA_DIR[$name]}")"
        icj="$data_dir/cloud.json"
        _classify_token_copy "$icj" " (instancia $name)"
    done
}

# _warn_token_loss_if_needed
# Only relevant when ENGRAM_CLOUD_TOKEN is live in the environment right now
# (see header comment). If no surviving non-empty copy exists anywhere,
# prints a prominent warning naming the exact file:line locations and what
# was checked, BEFORE the numbered remediation steps. If a surviving copy
# exists, says so briefly instead. Never prints the token value.
_warn_token_loss_if_needed() {
    compgen -e | grep -qx 'ENGRAM_CLOUD_TOKEN' || return 0

    local -a token_locs=()
    local loc
    while IFS= read -r loc; do
        [[ -n "$loc" ]] && token_locs+=("$loc")
    done < <(_token_definition_locations)

    local -a surviving=() checked=()
    while IFS= read -r loc; do
        [[ -n "$loc" ]] || continue
        case "$loc" in
            SURVIVING:*) surviving+=("${loc#SURVIVING:}") ;;
            OTHER:*)     checked+=("${loc#OTHER:} (guarda otro token, no el activo)") ;;
            EMPTY:*)     checked+=("${loc#EMPTY:} (sin token)") ;;
            MISSING:*)   checked+=("${loc#MISSING:} (no existe)") ;;
        esac
    done < <(_survey_token_copies)

    if [[ ${#surviving[@]} -gt 0 ]]; then
        printf 'AVISO: el token activo está guardado también en:\n'
        printf '  - %s\n' "${surviving[@]}"
        printf 'Puede continuar con seguridad: ese fichero guarda exactamente el mismo\nvalor, así que sobrevive aunque se borren las líneas de arriba.\n\n'
        return 0
    fi

    # The heading agrees in number with what is actually listed below it: a
    # message that says "esa línea" while printing two is the kind of small
    # inaccuracy that makes a user doubt the rest of the warning.
    case ${#token_locs[@]} in
        0) printf '\n*** AVISO: NO SE CONOCE OTRA COPIA DEL TOKEN ***\n\n' ;;
        1) printf '\n*** AVISO: ESA LÍNEA ES LA ÚNICA COPIA DEL TOKEN ***\n\n' ;;
        *) printf '\n*** AVISO: ESAS LÍNEAS SON LA ÚNICA COPIA DEL TOKEN ***\n\n' ;;
    esac
    if [[ ${#token_locs[@]} -gt 0 ]]; then
        printf 'ENGRAM_CLOUD_TOKEN está definido únicamente en:\n'
        printf '  - %s\n' "${token_locs[@]}"
    else
        printf 'ENGRAM_CLOUD_TOKEN está activo en esta sesión, pero no se ha podido\n'
        printf 'localizar la línea exacta que lo define.\n'
    fi
    printf '\n'
    if [[ ${#checked[@]} -gt 0 ]]; then
        printf 'Comprobado y sin token utilizable:\n'
        printf '  - %s\n' "${checked[@]}"
        printf '\n'
    fi
    printf 'GUARDE el valor del token (por ejemplo, en un gestor de contraseñas)\n'
    printf 'ANTES del paso 1 de abajo. Si borra esas líneas sin haberlo guardado,\n'
    printf 'tendrá que emitir un token nuevo en el servidor: no hay forma de\n'
    printf 'recuperar el valor actual.\n\n'
}

# ---------------------------------------------------------------------------
# Step 2 — install the router files (idempotent: code is always refreshed,
# user data such as cloud.json and router.json is left alone if present).
# ---------------------------------------------------------------------------
install_files() {
    section "Instalando ficheros del router"

    mkdir -p "$PREFIX_BIN" "$LIB_DIR" "$CONFIG_DIR" "$INSTANCES_ENV_DIR"

    install -m 0755 "$SCRIPT_DIR/bin/engram" "$PREFIX_BIN/engram"
    install -m 0755 "$SCRIPT_DIR/bin/engram-router" "$PREFIX_BIN/engram-router"
    install -m 0755 "$SCRIPT_DIR/bin/engram-doctor" "$PREFIX_BIN/engram-doctor"
    install -m 0755 "$SCRIPT_DIR/bin/engram-migrate" "$PREFIX_BIN/engram-migrate"
    ln -sf "$PREFIX_BIN/engram-router" "$PREFIX_BIN/engram-where"
    install -m 0644 "$SCRIPT_DIR/lib/router.sh" "$LIB_DIR/router.sh"

    say "Binarios instalados en $PREFIX_BIN"
}

# ---------------------------------------------------------------------------
# Step 3 — resolve the real engram binary generically (never hardcode a
# specific install path) and install the systemd user template unit.
# ---------------------------------------------------------------------------
find_real_engram() {
    local dir
    local IFS=:
    for dir in $PATH; do
        [[ -z "$dir" ]] && continue
        [[ "$dir" == "$PREFIX_BIN" ]] && continue
        if [[ -x "$dir/engram" ]]; then
            printf '%s\n' "$dir/engram"
            return 0
        fi
    done
    return 1
}

install_systemd_unit() {
    section "Instalando unidad systemd --user (engram@.service)"

    if ! command -v systemctl >/dev/null 2>&1; then
        say "systemd no disponible en este sistema; se omite la unidad de usuario."
        return
    fi

    local real_engram
    if ! real_engram="$(find_real_engram)"; then
        say "AVISO: no se encontró el binario real 'engram' en PATH; no se puede instalar la unidad systemd todavía."
        say "       Instale/añada engram al PATH y vuelva a ejecutar este instalador."
        return
    fi

    mkdir -p "$SYSTEMD_USER_DIR"
    sed "s|%h/.local/bin/engram-real-path-placeholder|$real_engram|" \
        "$SCRIPT_DIR/systemd/engram@.service" > "$SYSTEMD_USER_DIR/engram@.service"

    systemctl --user daemon-reload 2>/dev/null || true
    say "Unidad instalada en $SYSTEMD_USER_DIR/engram@.service (binario real: $real_engram)."
    say "No se ha habilitado ni arrancado ningún daemon automáticamente."
    say "Para habilitar una instancia manualmente:"
    say "  systemctl --user enable --now engram@<instancia>.service"
}

# ---------------------------------------------------------------------------
# Step 4 — choose which instances to provision.
#
# Instance names are free-form: the core treats them as data (a map key, an
# `engram-<name>` directory suffix, and %i in the templated systemd unit).
# Nothing hardcodes "work" or "personal".
#
# One instance per CLOUD you replicate to — never one per context. Instances
# are isolation boundaries, not folders: they share no database, so a search in
# one cannot see the others. Separating clients that all sync to the same cloud
# belongs in Engram's project names, not in extra instances.
# ---------------------------------------------------------------------------
INSTANCE_NAME_RE='^[a-z0-9][a-z0-9-]{0,31}$'

# Namespaces are asked one per line, like instance names, instead of one
# space-separated line. A single line gives no second chance: a typo or a
# forgotten entry can only be fixed by editing router.json by hand afterwards,
# which is exactly what happened on the first real install.
ask_namespaces_for() {
    # Every prompt and message here goes to stderr on purpose: this function
    # returns the collected namespaces on stdout, so anything else printed
    # there would be captured by the caller and written into router.json as
    # rules. That is exactly what happened before this redirect existed.
    #
    # Existing namespaces are pre-loaded rather than replaced, so adding one
    # more to an instance does not mean retyping the ones already there.
    local name="$1" current="$2"
    local -a collected=()
    local ns="" existing=""

    for existing in $current; do
        collected+=("$existing")
    done

    say >&2 "Ahora, qué repositorios usarán '$name'."
    say >&2 "Se decide por el remote de git: todo repositorio cuyo origin empiece"
    say >&2 "por uno de estos prefijos irá a esta instancia. Uno por línea."
    say >&2 "Formato: host[:puerto]/propietario  — sin https://, sin .git y sin el"
    say >&2 "nombre del repositorio; solo hasta el propietario u organización."
    say >&2 "Ejemplos: github.com/mi-organizacion   gitlab.miempresa.com:8443/mi-usuario"
    if [[ ${#collected[@]} -gt 0 ]]; then
        say >&2 ""
        say >&2 "Ya configurados para '$name':"
        local c
        for c in "${collected[@]}"; do
            say >&2 "  - $c"
        done
        say >&2 "Escriba uno nuevo para AÑADIRLO. Para quitar uno, escríbalo con un"
        say >&2 "guion delante, por ejemplo: -${collected[0]}"
    fi

    while :; do
        local prompt
        if [[ ${#collected[@]} -eq 0 ]]; then
            prompt="  Prefijo, o Enter si '$name' no debe recibir ningún repositorio: "
        else
            prompt="  Otro prefijo, o Enter si ya no quiere más: "
        fi
        # Cleared before each read and broken on failure: read leaves the
        # previous value in place at EOF, so a validation retry loop would
        # otherwise spin forever once input ran out.
        ns=""
        read -r -p "$prompt" ns || break
        [[ -z "$ns" ]] && break

        # Validated against the reflex errors: pasting the whole clone URL,
        # keeping the .git suffix, or including the repository name. All three
        # produce a prefix that can never match a normalized remote, and the
        # only symptom would be a repository silently not routing.
        if [[ "$ns" != -* ]]; then
            local bad=""
            case "$ns" in
                *://*)   bad="no incluya el esquema: escriba '${ns#*://}' en vez de '$ns'" ;;
                *.git)   bad="no incluya '.git': escriba '${ns%.git}' en vez de '$ns'" ;;
                */*/*/*) bad="sobra parte de la ruta: use solo host[:puerto]/propietario" ;;
            esac
            if [[ -z "$bad" && ! "$ns" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)?$ ]]; then
                bad="formato no válido. Debe ser host[:puerto]/propietario, p.ej. github.com/mi-org"
            fi
            if [[ -n "$bad" ]]; then
                say >&2 "  $bad"
                continue
            fi
        fi

        # A leading "-" removes an entry instead of adding one.
        if [[ "$ns" == -* ]]; then
            local drop="${ns#-}" kept=() found="" c
            for c in ${collected[@]+"${collected[@]}"}; do
                if [[ "$c" == "$drop" ]]; then found=1; else kept+=("$c"); fi
            done
            if [[ -n "$found" ]]; then
                collected=(${kept[@]+"${kept[@]}"})
                say >&2 "  quitado: $drop"
            else
                say >&2 "  '$drop' no estaba en la lista."
            fi
            continue
        fi

        local dup="" seen=""
        for seen in ${collected[@]+"${collected[@]}"}; do
            [[ "$seen" == "$ns" ]] && dup=1
        done
        if [[ -n "$dup" ]]; then
            say >&2 "  '$ns' ya está en la lista."
            continue
        fi

        collected+=("$ns")
        say >&2 "  añadido: $ns"
    done

    printf '%s' "${collected[*]-}"
}

# ---------------------------------------------------------------------------
# Existing-root detection (P9) — probed BEFORE ask_one_instance offers a
# default, so a brand-new instance never silently starts on an empty
# database while an existing installation's memories sit unreferenced in
# ~/.engram. See odd/tasks/engram-multi-cloud-router.md for the incident
# this guards against.
# ---------------------------------------------------------------------------

# _resolve_abs_path VALUE
# Expands ~/$HOME the same way router_expand_path does, then canonicalizes
# with readlink -f. Works even when the path does not exist yet (GNU
# readlink -f does not require the target to exist), which matters for a
# configured-but-not-yet-created instance directory. Falls back to the
# expanded-but-unresolved path if router.sh cannot be loaded or readlink
# fails, so comparisons degrade gracefully instead of erroring out.
_resolve_abs_path() {
    declare -f router_expand_path >/dev/null 2>&1 || _load_router_lib_best_effort || true
    local p="$1"
    if declare -f router_expand_path >/dev/null 2>&1; then
        p="$(router_expand_path "$p")"
    else
        p="${p/#\~/$HOME}"
    fi
    readlink -f -- "$p" 2>/dev/null || printf '%s\n' "$p"
}

# _shorten_home ABS_PATH
# Cosmetic inverse of the $HOME expansion above, only for display.
_shorten_home() {
    local p="$1"
    if [[ "$p" == "$HOME" ]]; then
        printf '~'
    elif [[ "$p" == "$HOME"/* ]]; then
        # Literal display text, not a path meant to expand — shellcheck
        # cannot tell the difference from a quoting mistake.
        # shellcheck disable=SC2088
        printf '~/%s' "${p#"$HOME"/}"
    else
        printf '%s' "$p"
    fi
}

# _existing_engram_roots
# Prints one resolved absolute path per line for every candidate root that
# contains engram.db: $HOME/.engram first, then $ENGRAM_DATA_DIR if set and
# different, de-duplicated by resolved path.
_existing_engram_roots() {
    local -a candidates=("$HOME/.engram")
    [[ -n "${ENGRAM_DATA_DIR:-}" ]] && candidates+=("$ENGRAM_DATA_DIR")

    local -A seen_roots=()
    local c abs
    for c in "${candidates[@]}"; do
        abs="$(_resolve_abs_path "$c")"
        [[ -n "${seen_roots[$abs]:-}" ]] && continue
        seen_roots[$abs]=1
        [[ -e "$abs/engram.db" ]] && printf '%s\n' "$abs"
    done
}

# _root_is_claimed ROOT
# A root is claimed when it resolves to the same path as a directory already
# pushed this run (INSTANCE_DIRS, a global array populated by push_instance —
# see ask_instances). By the time ask_one_instance is asked for a brand-new
# instance, every instance kept or configured earlier in this same run —
# whether loaded from router.json or just typed — has already been pushed,
# so this one check covers both "already in router.json" and "chosen earlier
# in this run" without consulting router.json a second time.
_root_is_claimed() {
    local root="$1" d
    for d in ${INSTANCE_DIRS[@]+"${INSTANCE_DIRS[@]}"}; do
        [[ -n "$d" ]] || continue
        [[ "$(_resolve_abs_path "$d")" == "$root" ]] && return 0
    done
    return 1
}

# _human_size_mb BYTES
# Formats a byte count as "N.N MB" (or "N.NN GB" past 1 GiB), matching the
# style used elsewhere in this installer's output.
_human_size_mb() {
    # LC_ALL=C: the locale's decimal separator must not leak into a
    # figure that later gets compared/matched as "N.N MB".
    LC_ALL=C awk -v b="$1" 'BEGIN {
        mb = b / 1048576
        if (mb >= 1024) { printf "%.2f GB", mb / 1024 } else { printf "%.1f MB", mb }
    }'
}

# _describe_engram_root ROOT
# Prints "<size>, <N observaciones>, <M proyectos>" for the engram.db under
# ROOT. Reads the database the same way bin/engram-migrate does — same
# table (observations), same "not deleted" filter (deleted_at IS NULL) — but
# opened with sqlite3's own -readonly flag: a live `engram serve` may hold
# this file in WAL mode, and this call must never take a write lock or
# create/modify -wal/-shm state. If sqlite3 is missing or the query fails,
# reports that plainly instead of fabricating a number — the exact failure
# mode this installer exists to avoid.
_describe_engram_root() {
    local root="$1"
    local db="$root/engram.db"
    local size_bytes size_str obs proj obs_str proj_str

    if size_bytes="$(stat -c %s "$db" 2>/dev/null)" && [[ -n "$size_bytes" ]]; then
        size_str="$(_human_size_mb "$size_bytes")"
    else
        size_str="tamaño desconocido"
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        obs="$(sqlite3 -readonly "$db" \
            "SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL;" 2>/dev/null || true)"
        proj="$(sqlite3 -readonly "$db" \
            "SELECT COUNT(DISTINCT project) FROM observations WHERE deleted_at IS NULL;" 2>/dev/null || true)"
        if [[ "$obs" =~ ^[0-9]+$ ]]; then
            obs_str="$obs observaciones"
        else
            obs_str="no se pudo leer el número de observaciones"
        fi
        if [[ "$proj" =~ ^[0-9]+$ ]]; then
            proj_str="$proj proyectos"
        else
            proj_str="no se pudo leer el número de proyectos"
        fi
    else
        obs_str="no se pudo leer el número de observaciones (sqlite3 no disponible)"
        proj_str="no se pudo leer el número de proyectos (sqlite3 no disponible)"
    fi

    printf '%s, %s, %s' "$size_str" "$obs_str" "$proj_str"
}

# _validate_instance_dir DIR
# The path checks ask_one_instance has always run, factored out so both the
# normal-default prompt and the no-default detection prompt share exactly
# one implementation.
_validate_instance_dir() {
    local dir="$1"
    # Caught early because mkdir would otherwise abort the whole install
    # several steps later, after credentials had already been typed.
    if [[ -e "$dir" && ! -d "$dir" ]]; then
        say "  '$dir' existe y no es una carpeta. Elija otra ruta."
        return 1
    fi
    if [[ ! -e "$dir" ]]; then
        local parent="$dir"
        while [[ ! -e "$parent" && "$parent" != "/" ]]; do parent="$(dirname "$parent")"; done
        if [[ ! -w "$parent" ]]; then
            say "  No hay permiso de escritura en '$parent'. Elija otra ruta."
            return 1
        fi
    fi
    return 0
}

# Asks for one instance's directory, credentials and namespaces. Used both for
# a brand-new instance and for modifying one that already exists.
ask_one_instance() {
    local name="$1" cur_dir="${2:-}" cur_ns="${3:-}"

    local default_dir="${cur_dir:-$HOME/.local/share/engram-$name}" dir=""
    say "  Carpeta donde '$name' guardará su base de datos."

    # Detection only applies to a brand-new instance (cur_dir empty). When
    # modifying one that already exists, its current directory stays the
    # default — forcing an explicit answer there would be a needless trap
    # for someone just changing namespaces.
    local -a unclaimed_roots=()
    if [[ -z "$cur_dir" ]]; then
        local root
        while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            _root_is_claimed "$root" || unclaimed_roots+=("$root")
        done < <(_existing_engram_roots)
    fi

    if [[ ${#unclaimed_roots[@]} -gt 0 ]]; then
        say "  DETECTADA una instalación de Engram existente:"
        for root in "${unclaimed_roots[@]}"; do
            say "    $(_shorten_home "$root")  ->  $(_describe_engram_root "$root")"
        done
        say ""
        say "  Ninguna instancia la está usando todavía. Si empieza con una"
        say "  carpeta nueva, esas memorias siguen ahí pero NINGUNA instancia"
        say "  las verá: los repos que enrute encontrarán una base vacía."
        say ""
        if [[ ${#unclaimed_roots[@]} -eq 1 ]]; then
            say "  Escriba $(_shorten_home "${unclaimed_roots[0]}") para adoptarla, o 'nueva' para empezar vacío."
        else
            say "  Escriba una de las rutas de arriba para adoptarla, o 'nueva' para empezar vacío."
        fi
        while :; do
            dir=""
            # read's exit status is the only way to tell "the user pressed
            # Enter" from "there is no more input". They must not be treated
            # alike here: this branch has no default to fall back on, so
            # re-asking an exhausted stream would print the refusal and read
            # EOF again forever, consuming nothing. The default-offering
            # branch below is immune only because it collapses an EOF read
            # into its default and leaves the loop on the first pass.
            local read_ok=1
            read -r -p "  Carpeta (sin valor por defecto): " dir || read_ok=0
            # A failed read still yields a final line that had no trailing
            # newline, so only a failure with nothing in hand is EOF.
            if [[ $read_ok -eq 0 && -z "$dir" ]]; then
                say ""
                say "  Entrada agotada sin respuesta (EOF)."
                say "  Esta pregunta no tiene valor por defecto a propósito: elegir por"
                say "  usted arriesgaría arrancar '$name' con una base vacía, o adoptar"
                say "  memorias que quizá no le corresponden. Instalación detenida."
                exit 1
            fi
            if [[ -z "$dir" ]]; then
                say "  No se acepta un valor vacío aquí: escriba una ruta o 'nueva'."
                continue
            fi
            if [[ "$dir" == "nueva" ]]; then
                dir="$default_dir"
            else
                dir="${dir/#\~/$HOME}"
            fi
            _validate_instance_dir "$dir" || { dir=""; continue; }
            break
        done
    else
        say "  Pulse Enter para crear una nueva ahí, o escriba la ruta de una"
        say "  instalación de Engram que ya exista para reutilizar sus memorias."
        say "  Formato: ruta absoluta, o empezando por ~ (ej: ~/.engram)."
        while :; do
            dir=""
            read -r -p "  Carpeta [Enter = $default_dir]: " dir || dir=""
            dir="${dir:-$default_dir}"
            dir="${dir/#\~/$HOME}"
            _validate_instance_dir "$dir" || { dir=""; continue; }
            break
        done
    fi

    # Reusing an existing installation root keeps its memories, its enrollments
    # and its sync cursors; a fresh directory silently starts from an empty
    # database while the old one sits there untouched.
    if [[ -e "$dir/engram.db" ]]; then
        say "  Reutiliza una instalación existente: conserva memorias y enrolamientos."
    fi

    ASKED_DIR="$dir"
    ASKED_NS="$(ask_namespaces_for "$name" "$cur_ns")"
}

# Reads an existing router.json into INSTALLED_* arrays. Reuses the shared
# library rather than parsing JSON a second way.
load_existing_config() {
    INSTALLED_NAMES=()
    INSTALLED_DIRS=()
    INSTALLED_NS=()
    [[ -r "$CONFIG_FILE" ]] || return 1

    # shellcheck source=lib/router.sh
    source "$LIB_DIR/router.sh" 2>/dev/null || source "$SCRIPT_DIR/lib/router.sh"
    router_load_config "$CONFIG_FILE" || return 1
    [[ ${#INSTANCE_NAMES[@]} -gt 0 ]] || return 1

    local n i ns
    for n in "${INSTANCE_NAMES[@]}"; do
        ns=""
        for i in "${!RULE_PREFIXES[@]}"; do
            [[ "${RULE_INSTANCES[$i]}" == "$n" ]] && ns+="${ns:+ }${RULE_PREFIXES[$i]}"
        done
        INSTALLED_NAMES+=("$n")
        INSTALLED_DIRS+=("${INSTANCE_DATA_DIR[$n]:-}")
        INSTALLED_NS+=("$ns")
    done
    return 0
}

show_existing_config() {
    local i
    say "Configuración existente en $CONFIG_FILE:"
    for i in "${!INSTALLED_NAMES[@]}"; do
        printf '  %-16s -> %s\n' "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}"
        printf '  %-16s    %s\n' "" "${INSTALLED_NS[$i]:-(sin namespaces)}"
    done
}

# Adds a name/dir/namespaces triple to the set that will be written out.
push_instance() {
    INSTANCES_TO_PROVISION+=("$1")
    INSTANCE_DIRS+=("$2")
    INSTANCE_NS+=("$3")
}

read_new_name() {
    local prompt="$1" name=""
    while :; do
        read -r -p "$prompt" name || true
        [[ -z "$name" ]] && { printf ''; return 1; }
        if [[ ! "$name" =~ $INSTANCE_NAME_RE ]]; then
            say "Nombre inválido: use minúsculas, dígitos y guiones (máx. 32). Ej: work, cliente-acme"
            continue
        fi
        local seen=""
        for seen in ${INSTANCES_TO_PROVISION[@]+"${INSTANCES_TO_PROVISION[@]}"}; do
            [[ "$seen" == "$name" ]] && { say "'$name' ya está en la lista."; continue 2; }
        done
        printf '%s' "$name"
        return 0
    done
}

ask_instances() {
    section "Selección de instancias"

    INSTANCES_TO_PROVISION=()
    INSTANCE_DIRS=()
    INSTANCE_NS=()
    REPROVISION=()

    if [[ ! -t 0 ]]; then
        if load_existing_config; then
            local i
            for i in "${!INSTALLED_NAMES[@]}"; do
                push_instance "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
            done
            say "Entrada no interactiva: se conserva la configuración existente."
        else
            push_instance work "$HOME/.local/share/engram-work" ""
            say "Entrada no interactiva: se instala solo la instancia 'work' por defecto."
        fi
        return
    fi

    if load_existing_config; then
        show_existing_config
        say ""
        say "  1) Conservarla sin cambios  (recomendado si solo quiere reinstalar)"
        say "  2) Añadir una instancia nueva"
        say "  3) Modificar una existente  (cambiar su carpeta o sus namespaces)"
        say "  4) Empezar de cero  (descarta lo de arriba y vuelve a preguntarlo todo)"
        local choice=""
        while :; do
            choice=""
            read -r -p "Escriba 1, 2, 3 o 4 — o pulse Enter para la opción 1: " choice || choice=1
            choice="${choice:-1}"
            case "$choice" in
                1|2|3|4) break ;;
                *) say "  '$choice' no es una opción. Escriba 1, 2, 3 o 4." ;;
            esac
        done

        local i
        case "$choice" in
            1)
                for i in "${!INSTALLED_NAMES[@]}"; do
                    push_instance "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
                done
                say "Configuración conservada."
                return
                ;;
            2)
                for i in "${!INSTALLED_NAMES[@]}"; do
                    push_instance "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
                done
                local name
                say ""
                say "Escriba el nombre de la instancia nueva (ej: cliente-acme)."
                say "Formato: minúsculas, dígitos y guiones; empieza por letra o dígito;"
                say "máximo 32 caracteres."
                while name="$(read_new_name "  Nombre, o Enter si ya no quiere añadir más: ")"; do
                    [[ -z "$name" ]] && break
                    ask_one_instance "$name"
                    push_instance "$name" "$ASKED_DIR" "$ASKED_NS"
                    REPROVISION+=("$name")
                    say "Añadida instancia '$name' -> $ASKED_DIR"
                done
                return
                ;;
            3)
                # "¿Cuál desea modificar?" read as a yes/no question in real use
                # and got answered "s", which then looked like a missing
                # instance. Ask for a name explicitly and offer a way out.
                local target=""
                say ""
                say "Escriba el NOMBRE de la instancia que quiere modificar."
                say "Disponibles: ${INSTALLED_NAMES[*]}"
                read -r -p "  Instancia a modificar (Enter para cancelar): " target || true
                if [[ -z "$target" ]]; then
                    for i in "${!INSTALLED_NAMES[@]}"; do
                        push_instance "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
                    done
                    say "Cancelado: no se ha modificado nada."
                    return
                fi
                for i in "${!INSTALLED_NAMES[@]}"; do
                    if [[ "${INSTALLED_NAMES[$i]}" == "$target" ]]; then
                        ask_one_instance "$target" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
                        push_instance "$target" "$ASKED_DIR" "$ASKED_NS"
                        REPROVISION+=("$target")
                    else
                        push_instance "${INSTALLED_NAMES[$i]}" "${INSTALLED_DIRS[$i]}" "${INSTALLED_NS[$i]}"
                    fi
                done
                if [[ ${#REPROVISION[@]} -eq 0 ]]; then
                    say "No existe ninguna instancia llamada '$target'."
                    say "Nombres válidos: ${INSTALLED_NAMES[*]}. No se ha modificado nada."
                fi
                return
                ;;
            4) say "Se descarta la configuración anterior." ;;
        esac
    fi

    say "Una INSTANCIA es una instalación de Engram independiente: su propia base"
    say "de datos y su propio servidor de destino. Cree una por cada Engram Cloud"
    say "al que sincronice, y no más: dos instancias no comparten memorias, así que"
    say "una búsqueda en una no encuentra nada de la otra."
    say ""
    say "El nombre es suyo: sirve para referirse a ella (ej: work, personal, cliente-acme)."
    say "Formato aceptado: minúsculas, dígitos y guiones. Debe empezar por letra o"
    say "dígito, máximo 32 caracteres. Sin espacios, mayúsculas ni acentos."

    local name=""
    while :; do
        local prompt
        if [[ ${#INSTANCES_TO_PROVISION[@]} -eq 0 ]]; then
            prompt="Nombre de la primera instancia (Enter para llamarla 'work'): "
        else
            prompt="Nombre de otra instancia, o Enter si ya no quiere más: "
        fi

        read -r -p "$prompt" name || true

        if [[ -z "$name" ]]; then
            if [[ ${#INSTANCES_TO_PROVISION[@]} -eq 0 ]]; then
                ask_one_instance work
                push_instance work "$ASKED_DIR" "$ASKED_NS"
                REPROVISION+=(work)
            fi
            break
        fi

        if [[ ! "$name" =~ $INSTANCE_NAME_RE ]]; then
            say "Nombre inválido: use minúsculas, dígitos y guiones (máx. 32). Ej: work, cliente-acme"
            continue
        fi

        local dup="" existing=""
        for existing in ${INSTANCES_TO_PROVISION[@]+"${INSTANCES_TO_PROVISION[@]}"}; do
            [[ "$existing" == "$name" ]] && dup=1
        done
        if [[ -n "$dup" ]]; then
            say "'$name' ya está en la lista."
            continue
        fi

        ask_one_instance "$name"
        push_instance "$name" "$ASKED_DIR" "$ASKED_NS"
        REPROVISION+=("$name")
        say "Añadida instancia '$name' -> $ASKED_DIR"
    done

    say "Instancias configuradas: ${INSTANCES_TO_PROVISION[*]}"
}

# ---------------------------------------------------------------------------
# Step 5 — provision each selected instance: data dir, cloud.json 0600.
# Never echoes or logs the token.
# ---------------------------------------------------------------------------
provision_instance() {
    local name="$1"
    local data_dir="$2"
    local cloud_json="$data_dir/cloud.json"

    section "Aprovisionando instancia: $name"

    if [[ -d "$data_dir" ]]; then
        say "Usando el directorio existente $data_dir (permisos sin tocar)."
    else
        mkdir -p "$data_dir"
        chmod 0700 "$data_dir"
    fi

    if [[ -e "$cloud_json" ]]; then
        say "Ya existe $cloud_json — se conserva sin modificar (re-ejecución idempotente)."
        say "AVISO: si esta instancia ya tenía enrolamientos de una instalación de"
        say "       instancia única previa, revise mem_search/engram-doctor: puede"
        say "       haber mutaciones pendientes 'destination-blind' (sin identidad"
        say "       de servidor) que ahora deben confirmarse manualmente."
        return
    fi

    if [[ ! -t 0 ]]; then
        say "Entrada no interactiva: se omite el aprovisionamiento de credenciales para '$name'."
        say "Ejecute este instalador de forma interactiva para configurar $cloud_json."
        return
    fi

    local server=""
    say "URL del Engram Cloud de '$name'. Debe empezar por https:// — Engram se"
    say "niega a enviar el token por HTTP sin cifrar."
    # Engram refuses to send a bearer token over plain HTTP, verified against
    # v2.0.0, so an http:// destination could never sync. Rejected here rather
    # than on the first push, when the token has already been typed.
    while :; do
        server=""
        read -r -p "  URL (ej: https://engram.miempresa.com): " server || break
        [[ -z "$server" ]] && break
        case "$server" in
            https://?*) break ;;
            http://*)   say "  Debe ser https://. Engram no envía el token por HTTP sin cifrar." ;;
            *://*)      say "  Esquema no admitido. Use https://" ;;
            *)          say "  Falta el esquema. Escriba la URL completa, empezando por https://" ;;
        esac
    done

    if [[ -z "$server" ]]; then
        say "URL vacía: '$name' queda SIN destino y no podrá sincronizar."
        say "Vuelva a ejecutar este instalador cuando tenga la URL."
        return
    fi

    local token=""
    say "Token de '$name'. Lo obtiene el administrador del servidor en su panel,"
    say "en /dashboard/admin/users. No se mostrará mientras lo escribe."
    say "Formato: la cadena tal cual se la dieron, sin comillas ni espacios."
    read -r -s -p "  Token: " token || true
    echo
    if [[ -z "$token" ]]; then
        say "Token vacío: '$name' queda SIN credenciales y no podrá sincronizar."
        say "Vuelva a ejecutar este instalador cuando tenga el token."
        return
    fi

    # Written directly, never echoed and never logged.
    #
    # The URL key MUST be "server_url", not "server". Engram reads "server_url";
    # given "server" it reports `not configured (no effective server URL)` while
    # still reading the token from the same file, so the instance looks half
    # configured instead of failing outright. Verified against engram v2.0.0.
    umask 077
    printf '{\n  "server_url": "%s",\n  "token": "%s"\n}\n' "$server" "$token" > "$cloud_json"
    chmod 0600 "$cloud_json"
    umask 022

    say "cloud.json escrito con permisos 0600 en $cloud_json"

    unset token server
}

write_instance_autosync_env() {
    local name="$1"
    local autosync_file="$INSTANCES_ENV_DIR/$name.env"
    # Create the directory here rather than trusting the mkdir in install_files:
    # a real install failed with "No such file or directory" at this line even
    # though that mkdir had reported success, and the cause was never
    # identified. Whatever removed it, writing a file is the right place to
    # guarantee its directory.
    mkdir -p "$INSTANCES_ENV_DIR"
    # Autosync is opt-in per instance (verified: unset means no
    # "[autosync] started" line). Left commented out by default; the
    # colleague enables it explicitly per instance if wanted.
    if [[ ! -e "$autosync_file" ]]; then
        cat > "$autosync_file" <<EOF
# Uncomment to enable autosync for the "$name" instance.
# ENGRAM_CLOUD_AUTOSYNC=1
EOF
    fi
}

# ---------------------------------------------------------------------------
# Write router.json from the instances actually provisioned.
#
# The shipped config/router.example.json is an example: its rules name
# placeholder namespaces and its instances name placeholder paths. Installing
# it verbatim would leave every repository unmatched, so the real file is
# generated here and the rules are asked for.
# ---------------------------------------------------------------------------
# Escapes a value for inclusion in a JSON string. Backslash first, then the
# quote, or the backslashes added by the second pass would be escaped again.
# Without this a namespace or a data directory containing a double quote —
# legal in a Linux path — produced a file that reported success and then
# failed to parse, which is the quiet kind of breakage this tool exists to
# avoid.
json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

# Parses the file just written with the shared library and compares what came
# back against what was requested. Counting is enough: a file that parses but
# lost an entry is as broken as one that does not parse at all.
verify_written_config() {
    local want_rules="$1" want_instances="$2"

    # shellcheck source=lib/router.sh
    source "$LIB_DIR/router.sh" 2>/dev/null || source "$SCRIPT_DIR/lib/router.sh" || return 1

    RULE_PREFIXES=(); RULE_INSTANCES=(); INSTANCE_NAMES=()
    router_load_config "$CONFIG_FILE" 2>/dev/null || return 1

    local got_rules="${#RULE_PREFIXES[@]}" got_instances="${#INSTANCE_NAMES[@]}"
    if [[ "$got_rules" -ne "$want_rules" || "$got_instances" -ne "$want_instances" ]]; then
        printf '  releídas %s regla(s) y %s instancia(s); se esperaban %s y %s\n' \
            "$got_rules" "$got_instances" "$want_rules" "$want_instances" >&2
        return 1
    fi

    local name
    for name in ${INSTANCES_TO_PROVISION[@]+"${INSTANCES_TO_PROVISION[@]}"}; do
        [[ -n "${INSTANCE_DATA_DIR[$name]:-}" ]] || {
            printf "  la instancia '%s' no tiene data_dir tras releer\n" "$name" >&2
            return 1
        }
    done
    return 0
}

write_router_config() {
    section "Reglas de enrutado"

    local -a rule_lines=() instance_lines=()
    local i name dir prefix

    for i in "${!INSTANCES_TO_PROVISION[@]}"; do
        name="${INSTANCES_TO_PROVISION[$i]}"
        for prefix in ${INSTANCE_NS[$i]}; do
            rule_lines+=("    { \"prefix\": \"$(json_escape "$prefix")\", \"instance\": \"$(json_escape "$name")\" }")
        done
    done

    for i in "${!INSTANCES_TO_PROVISION[@]}"; do
        name="${INSTANCES_TO_PROVISION[$i]}"
        dir="${INSTANCE_DIRS[$i]}"
        instance_lines+=("    \"$(json_escape "$name")\": { \"data_dir\": \"$(json_escape "$dir")\" }")
    done

    # Values are emitted with %s so a "%" inside a namespace cannot be read as
    # a format directive, and commas are placed between entries only.
    emit_json_array() {
        local -n arr="$1"
        local i
        for i in "${!arr[@]}"; do
            printf '%s' "${arr[$i]}"
            [[ $i -lt $(( ${#arr[@]} - 1 )) ]] && printf ','
            printf '\n'
        done
    }

    # An existing config is backed up rather than refused: refusing would make
    # the installer unable to add or change an instance, which is its job.
    mkdir -p "$CONFIG_DIR"
    if [[ -e "$CONFIG_FILE" ]]; then
        cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
        say "Copia de la configuración anterior junto a $CONFIG_FILE"
    fi

    umask 022
    {
        printf '{\n  "rules": [\n'
        emit_json_array rule_lines
        printf '  ],\n  "instances": {\n'
        emit_json_array instance_lines
        printf '  }\n}\n'
    } > "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"

    say "Escrito $CONFIG_FILE (${#rule_lines[@]} regla(s), ${#instance_lines[@]} instancia(s))"

    # Read the file back with the same parser the router uses, and check it
    # describes what was just asked for. Writing a config the router cannot
    # parse while reporting success is the failure this whole tool exists to
    # prevent; an escaping bug did exactly that before this check existed.
    if ! verify_written_config "${#rule_lines[@]}" "${#instance_lines[@]}"; then
        # Backups are named .bak.YYYYMMDD_HHMMSS, so the glob's sorted order is
        # chronological and the last entry is the newest. No ls parsing.
        local restored="" newest=""
        local -a backups=("$CONFIG_FILE".bak.*)
        if [[ -e "${backups[0]}" ]]; then
            newest="${backups[-1]}"
            cp -p "$newest" "$CONFIG_FILE"
            restored=" Se ha restaurado la configuración anterior desde $(basename "$newest")."
        fi
        printf '\nERROR: la configuración escrita no se puede volver a leer.%s\n' "$restored" >&2
        printf 'No se ha completado la instalación. Revise %s\n' "$CONFIG_FILE" >&2
        exit 1
    fi
    say "Verificado: la configuración se relee correctamente."
    if [[ ${#rule_lines[@]} -eq 0 ]]; then
        say "SIN REGLAS: ningún repositorio se enrutará y toda operación de cloud"
        say "            será rechazada hasta que las añada."
    fi
}

# ---------------------------------------------------------------------------
# Step 6 — verify the shim actually wins in PATH.
# ---------------------------------------------------------------------------
verify_path_precedence() {
    section "Verificando precedencia en PATH"
    local resolved
    resolved="$(command -v engram 2>/dev/null || true)"
    if [[ "$resolved" == "$PREFIX_BIN/engram" ]]; then
        say "OK: 'engram' resuelve al shim instalado ($resolved)."
        return 0
    fi

    say "AVISO: 'engram' resuelve a: ${resolved:-"(no encontrado)"}"
    say "       en vez de al shim instalado en $PREFIX_BIN/engram."
    say ""
    say "Cómo solucionarlo: añada $PREFIX_BIN al PATH ANTES que cualquier otra"
    say "ruta que ya contenga 'engram' (por ejemplo, antes de la línea que añade"
    say "Homebrew al PATH). En ~/.bashrc y ~/.profile:"
    say "  export PATH=\"$PREFIX_BIN:\$PATH\""
    say "Luego abra una terminal nueva y vuelva a ejecutar: engram-doctor"
    return 1
}

main() {
    say "Instalador del router multi-nube de Engram"

    detect_hazardous_exports
    install_files
    install_systemd_unit
    ask_instances

    # Only instances the user just added or changed are provisioned: the ones
    # kept from an existing config already have their credentials, and asking
    # again would mean re-typing a token to change nothing.
    local idx=0 inst touch
    for inst in "${INSTANCES_TO_PROVISION[@]}"; do
        touch=""
        for name in ${REPROVISION[@]+"${REPROVISION[@]}"}; do
            [[ "$name" == "$inst" ]] && touch=1
        done
        if [[ -n "$touch" ]]; then
            provision_instance "$inst" "${INSTANCE_DIRS[$idx]}"
            write_instance_autosync_env "$inst"
        fi
        idx=$((idx + 1))
    done

    write_router_config

    section "Aviso final"
    say "Si ya tenía una instalación de Engram de instancia única en uso, es"
    say "posible que existan proyectos ya enrolados y mutaciones de sincronización"
    say "pendientes que son 'destination-blind' (sin saber a qué servidor"
    say "pertenecen). Revíselas antes de habilitar sync en varias instancias."

    local path_ok=1
    verify_path_precedence || path_ok=0

    section "Ejecutando engram-doctor"
    "$PREFIX_BIN/engram-doctor" || true

    echo
    if [[ $path_ok -eq 1 ]]; then
        say "Instalación completa."
    else
        say "Instalación completa, PERO revise el aviso de precedencia en PATH de arriba."
    fi
}

main "$@"
