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

        if [[ ${#file_hits[@]} -eq 0 ]]; then
            cat <<'EOF'
Los ficheros ya están limpios: solo queda una sesión antigua.

  1. Cierre sesión y vuelva a entrar.
     El gestor de systemd --user hereda su entorno al arrancar la sesión y
     no lo suelta: `systemctl --user unset-environment` no puede quitar esas
     variables, solo las que él mismo definió.
  2. Compruebe con: env | grep ENGRAM_CLOUD   (no debe salir nada)
  3. Vuelva a ejecutar este instalador.
EOF
        else
            cat <<'EOF'
Cómo resolverlo antes de reintentar:
  1. Elimine o comente las líneas ENGRAM_CLOUD_* en los ficheros de arriba.
     Si hay uno bajo ~/.config/environment.d/, es entorno de sesión de
     systemd y lo hereda todo proceso de la sesión, no solo las shells.
  2. Cierre sesión y vuelva a entrar. Un `source` no basta: las variables ya
     están exportadas en los procesos vivos.
  3. Compruebe con: env | grep ENGRAM_CLOUD   (no debe salir nada)
  4. Vuelva a ejecutar este instalador.
EOF
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
# Step 2 — install the router files (idempotent: code is always refreshed,
# user data such as cloud.json and router.json is left alone if present).
# ---------------------------------------------------------------------------
install_files() {
    section "Instalando ficheros del router"

    mkdir -p "$PREFIX_BIN" "$LIB_DIR" "$CONFIG_DIR" "$INSTANCES_ENV_DIR"

    install -m 0755 "$SCRIPT_DIR/bin/engram" "$PREFIX_BIN/engram"
    install -m 0755 "$SCRIPT_DIR/bin/engram-router" "$PREFIX_BIN/engram-router"
    install -m 0755 "$SCRIPT_DIR/bin/engram-doctor" "$PREFIX_BIN/engram-doctor"
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

ask_instances() {
    section "Selección de instancias"
    say "Cree UNA instancia por cada Engram Cloud al que sincronice."
    say "No cree instancias por contexto de trabajo: no comparten base de datos,"
    say "así que una búsqueda en una no ve las memorias de las otras."

    INSTANCES_TO_PROVISION=()
    INSTANCE_DIRS=()

    if [[ ! -t 0 ]]; then
        INSTANCES_TO_PROVISION=(work)
        INSTANCE_DIRS=("$HOME/.local/share/engram-work")
        say "Entrada no interactiva: se instala solo la instancia 'work' por defecto."
        return
    fi

    local name=""
    while :; do
        local prompt="Nombre de la instancia"
        if [[ ${#INSTANCES_TO_PROVISION[@]} -eq 0 ]]; then
            prompt+=" [work]: "
        else
            prompt+=" (Enter para terminar): "
        fi

        read -r -p "$prompt" name || true

        if [[ -z "$name" ]]; then
            # First prompt defaults to "work"; later ones end the loop.
            if [[ ${#INSTANCES_TO_PROVISION[@]} -eq 0 ]]; then
                INSTANCES_TO_PROVISION=(work)
                INSTANCE_DIRS=("$HOME/.local/share/engram-work")
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

        local default_dir="$HOME/.local/share/engram-$name" dir=""
        read -r -p "  Directorio de datos [$default_dir]: " dir || true
        dir="${dir:-$default_dir}"
        dir="${dir/#\~/$HOME}"

        # Reusing an existing installation root keeps its memories, its
        # enrollments and its sync cursors: creating a fresh directory instead
        # would silently start from an empty database.
        if [[ -e "$dir/engram.db" ]]; then
            say "  Reutiliza una instalación existente: conserva memorias y enrolamientos."
        fi

        INSTANCES_TO_PROVISION+=("$name")
        INSTANCE_DIRS+=("$dir")
        say "Añadida instancia '$name' -> $dir"
    done

    say "Instancias a aprovisionar: ${INSTANCES_TO_PROVISION[*]}"
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
    read -r -p "URL del servidor Engram Cloud para '$name': " server || true
    if [[ -z "$server" ]]; then
        say "URL vacía: se omite $name (puede volver a ejecutar el instalador luego)."
        return
    fi

    local token=""
    read -r -s -p "Token de Engram Cloud para '$name' (no se mostrará): " token || true
    echo
    if [[ -z "$token" ]]; then
        say "Token vacío: se omite $name (puede volver a ejecutar el instalador luego)."
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
write_router_config() {
    section "Reglas de enrutado"

    if [[ -e "$CONFIG_FILE" ]]; then
        say "Ya existe $CONFIG_FILE — se conserva sin modificar."
        return
    fi

    local name dir idx=0 prefixes prefix
    local -a rule_lines=() instance_lines=()

    for name in "${INSTANCES_TO_PROVISION[@]}"; do
        if [[ -t 0 ]]; then
            say "Namespaces cuyos repositorios van a '$name'."
            say "Formato: host[:puerto]/propietario, separados por espacios."
            say "Ejemplo: github.com/mi-org gitlab.miempresa.com:8443/mi-usuario"
            read -r -p "  Namespaces de '$name' (Enter para ninguno): " prefixes || true
        else
            prefixes=""
        fi
        for prefix in $prefixes; do
            rule_lines+=("    { \"prefix\": \"$prefix\", \"instance\": \"$name\" }")
        done
    done

    for name in "${INSTANCES_TO_PROVISION[@]}"; do
        dir="${INSTANCE_DIRS[$idx]}"
        instance_lines+=("    \"$name\": { \"data_dir\": \"$dir\" }")
        idx=$((idx + 1))
    done

    # Values are emitted with %s so a "%" inside a namespace cannot be read as
    # a format directive, and commas are placed between entries only.
    emit_json_array() {
        # `local -n arr="$1" i` would make i a nameref too, and assigning it
        # a numeric index fails with "not a valid identifier".
        local -n arr="$1"
        local i
        for i in "${!arr[@]}"; do
            printf '%s' "${arr[$i]}"
            [[ $i -lt $(( ${#arr[@]} - 1 )) ]] && printf ','
            printf '\n'
        done
    }

    umask 022
    {
        printf '{\n  "rules": [\n'
        emit_json_array rule_lines
        printf '  ],\n  "instances": {\n'
        emit_json_array instance_lines
        printf '  }\n}\n'
    } > "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"

    say "Escrito $CONFIG_FILE"
    if [[ -z "$rules" ]]; then
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

    local idx=0
    for inst in "${INSTANCES_TO_PROVISION[@]}"; do
        provision_instance "$inst" "${INSTANCE_DIRS[$idx]}"
        write_instance_autosync_env "$inst"
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
