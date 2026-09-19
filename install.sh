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

    local hazard=0
    local hits=()

    local var
    for var in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do
        hits+=("entorno actual: $var")
        hazard=1
    done

    local f
    for f in "${DOTFILES_TO_SCAN[@]}"; do
        [[ -r "$f" ]] || continue
        if grep -qE '^\s*(export\s+)?ENGRAM_CLOUD_' "$f" 2>/dev/null; then
            hits+=("$f")
            hazard=1
        fi
    done
    for f in "$HOME"/.config/environment.d/*.conf; do
        [[ -e "$f" ]] || continue
        if grep -qE '^\s*ENGRAM_CLOUD_' "$f" 2>/dev/null; then
            hits+=("$f")
            hazard=1
        fi
    done

    if [[ $hazard -eq 1 ]]; then
        cat <<EOF

Se han detectado variables ENGRAM_CLOUD_* que anularían el enrutamiento
por cloud.json (ver hallazgo verificado: con estas variables presentes,
Engram usa ENGRAM_CLOUD_SERVER en vez de leer cloud.json, silenciosamente).

Ubicaciones encontradas:
EOF
        for h in "${hits[@]}"; do
            printf '  - %s\n' "$h"
        done
        cat <<EOF

Esta instalación NO va a editar automáticamente ningún dotfile.

Cómo resolverlo manualmente antes de reintentar:
  1. Elimine o comente las líneas "export ENGRAM_CLOUD_*" en los ficheros
     listados arriba.
  2. Si "\$HOME/.config/environment.d/engram-cloud.conf" existe, elimínelo o
     vacíelo (es entorno de sesión de systemd, se hereda en todos los
     procesos de la sesión).
  3. Cierre sesión y vuelva a entrar (o reinicie la sesión de systemd
     --user) para que el entorno quede limpio.
  4. Vuelva a ejecutar este instalador.

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

    if [[ -e "$CONFIG_FILE" ]]; then
        say "Ya existe $CONFIG_FILE — se conserva sin modificar."
    else
        install -m 0644 "$SCRIPT_DIR/config/router.example.json" "$CONFIG_FILE"
        say "Reglas por defecto instaladas en $CONFIG_FILE (edítelas si hace falta)."
    fi

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
# Step 4 — one-or-two instance prompt (default: one, work only).
# ---------------------------------------------------------------------------
ask_instances() {
    section "Selección de instancias"
    say "El caso habitual es UNA sola instancia (trabajo)."
    say "Tener también una instancia personal es una opción avanzada, nunca obligatoria."

    INSTANCES_TO_PROVISION=(work)

    if [[ -t 0 ]]; then
        local answer=""
        read -r -p "¿Tiene también una cuenta Engram personal que quiera enrutar por separado? [s/N]: " answer || true
        case "${answer,,}" in
            s|si|sí|y|yes) INSTANCES_TO_PROVISION+=(personal) ;;
            *) : ;;
        esac
    else
        say "Entrada no interactiva: se instala solo la instancia de trabajo por defecto."
    fi
}

# ---------------------------------------------------------------------------
# Step 5 — provision each selected instance: data dir, cloud.json 0600.
# Never echoes or logs the token.
# ---------------------------------------------------------------------------
provision_instance() {
    local name="$1"
    local data_dir="$HOME/.local/share/engram-$name"
    local cloud_json="$data_dir/cloud.json"

    section "Aprovisionando instancia: $name"

    mkdir -p "$data_dir"
    chmod 0700 "$data_dir"

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

    for inst in "${INSTANCES_TO_PROVISION[@]}"; do
        provision_instance "$inst"
        write_instance_autosync_env "$inst"
    done

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
