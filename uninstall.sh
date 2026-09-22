#!/usr/bin/env bash
#
# Remove engram-router from this machine.
#
# Two rules govern everything below.
#
# 1. Memory data is never removed unless explicitly asked for with --purge-data,
#    and even then one instance at a time. An instance directory holds an Engram
#    database whose memories may exist nowhere else: not every instance has a
#    cloud, and a cloud that was never reached has nothing to restore from.
#
# 2. Only paths this installer created are touched. An existing single-instance
#    installation at ~/.engram is never read, moved or removed.
set -euo pipefail

PREFIX_BIN="${ENGRAM_ROUTER_BIN:-$HOME/.local/bin}"
LIB_DIR="${ENGRAM_ROUTER_LIB_DIR:-$HOME/.local/lib/engram-router}"
CONFIG_DIR="${ENGRAM_ROUTER_CONFIG_DIR:-$HOME/.config/engram-router}"
CONFIG_FILE="$CONFIG_DIR/router.json"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
DATA_PREFIX="$HOME/.local/share/engram-"

PURGE_DATA=0
ASSUME_YES=0

say()     { printf '  %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
warn()    { printf '  AVISO: %s\n' "$*" >&2; }

usage() {
    cat <<'USAGE'
Uso: ./uninstall.sh [--purge-data] [--yes]

  --purge-data  Además, ofrece borrar los datos de cada instancia
                (~/.local/share/engram-<nombre>). Pregunta una por una.
                Sin esta opción los datos SIEMPRE se conservan.
  --yes         No pedir confirmación para desinstalar los componentes.
                No afecta a --purge-data, que siempre pregunta.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE_DATA=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) printf 'Opción desconocida: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Instance names come from the config when it is present, and from the data
# directories otherwise, so a partial or hand-edited install still uninstalls.
discover_instances() {
    local found=()
    if [[ -r "$CONFIG_FILE" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && found+=("$name")
        done < <(sed -n 's/.*"data_dir"[[:space:]]*:[[:space:]]*"[^"]*engram-\([a-z0-9-]\{1,\}\)".*/\1/p' "$CONFIG_FILE")
    fi
    local d
    for d in "$DATA_PREFIX"*; do
        [[ -d "$d" ]] || continue
        local name="${d#"$DATA_PREFIX"}"
        local seen="" f
        for f in ${found[@]+"${found[@]}"}; do [[ "$f" == "$name" ]] && seen=1; done
        [[ -z "$seen" ]] && found+=("$name")
    done
    printf '%s\n' ${found[@]+"${found[@]}"} | sort -u
}

confirm() {
    local prompt="$1" answer=""
    [[ ! -t 0 ]] && return 1
    read -r -p "$prompt" answer || true
    [[ "${answer,,}" =~ ^(s|si|sí|y|yes)$ ]]
}

INSTANCES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && INSTANCES+=("$line")
done < <(discover_instances)

# $PREFIX_BIN/engram is a special case: only a file carrying the
# engram-router-shim marker (a leftover from an install before the shell-hook
# routing existed) is ever removed. A real binary or any other foreign file
# there is never touched — see the header comment.
legacy_shim="$PREFIX_BIN/engram"
legacy_shim_is_ours=0
if [[ -f "$legacy_shim" && ! -L "$legacy_shim" ]] && grep -q 'engram-router-shim' "$legacy_shim" 2>/dev/null; then
    legacy_shim_is_ours=1
fi

section "Qué se va a eliminar"
COMPONENTS=(
    "$PREFIX_BIN/engram-router"
    "$PREFIX_BIN/engram-doctor"
    "$PREFIX_BIN/engram-migrate"
    "$PREFIX_BIN/engram-where"
    "$LIB_DIR"
    "$CONFIG_DIR"
    "$SYSTEMD_USER_DIR/engram@.service"
)
present=0
if [[ -e "$legacy_shim" || -L "$legacy_shim" ]]; then
    if [[ $legacy_shim_is_ours -eq 1 ]]; then
        say "eliminar   $legacy_shim  (shim antiguo retirado)"
        present=$((present + 1))
    else
        say "CONSERVAR  $legacy_shim  (no es nuestro: no lleva la marca engram-router-shim)"
    fi
fi
for path in "${COMPONENTS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        say "eliminar   $path"
        present=$((present + 1))
    fi
done

if [[ $present -eq 0 ]]; then
    say "No hay nada instalado en las rutas conocidas."
fi

if [[ ${#INSTANCES[@]} -gt 0 ]]; then
    say ""
    for name in "${INSTANCES[@]}"; do
        if [[ $PURGE_DATA -eq 1 ]]; then
            say "preguntar  ${DATA_PREFIX}${name}  (datos de la instancia '$name')"
        else
            say "CONSERVAR  ${DATA_PREFIX}${name}  (datos de la instancia '$name')"
        fi
    done
fi

say ""
say "Nunca se toca: ~/.engram, sus datos ni sus credenciales."

if [[ $present -gt 0 && $ASSUME_YES -eq 0 ]]; then
    if ! confirm "¿Continuar? [s/N]: "; then
        say "Cancelado. No se ha modificado nada."
        exit 0
    fi
fi

section "Deteniendo daemons"
if command -v systemctl >/dev/null 2>&1 && [[ ${#INSTANCES[@]} -gt 0 ]]; then
    for name in "${INSTANCES[@]}"; do
        if systemctl --user is-enabled "engram@$name.service" >/dev/null 2>&1 ||
           systemctl --user is-active  "engram@$name.service" >/dev/null 2>&1; then
            systemctl --user disable --now "engram@$name.service" >/dev/null 2>&1 || true
            say "engram@$name.service detenido y deshabilitado"
        fi
    done
else
    say "systemctl no disponible o sin instancias: nada que detener."
fi

section "Eliminando componentes"
if [[ $legacy_shim_is_ours -eq 1 ]]; then
    rm -rf -- "$legacy_shim"
    say "eliminado  $legacy_shim"
fi
for path in "${COMPONENTS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf -- "$path"
        say "eliminado  $path"
    fi
done

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
fi

section "Datos de las instancias"
if [[ ${#INSTANCES[@]} -eq 0 ]]; then
    say "No se han encontrado directorios de instancia."
elif [[ $PURGE_DATA -eq 0 ]]; then
    for name in "${INSTANCES[@]}"; do
        say "conservado ${DATA_PREFIX}${name}"
    done
    say ""
    say "Para borrarlos: ./uninstall.sh --purge-data"
else
    for name in "${INSTANCES[@]}"; do
        dir="${DATA_PREFIX}${name}"
        [[ -d "$dir" ]] || continue
        warn "'$dir' contiene la base de datos de la instancia '$name'."
        warn "Si esas memorias no se replicaron a un cloud, no existen en ningún otro sitio."
        if confirm "  Borrar DEFINITIVAMENTE los datos de '$name'? [s/N]: "; then
            rm -rf -- "$dir"
            say "borrado    $dir"
        else
            say "conservado $dir"
        fi
    done
fi

section "Después de desinstalar"
say "El comando 'engram' vuelve a ser el binario original, sin enrutado."
say "Si su ~/.bashrc o ~/.zshrc tiene una línea 'eval \"\$(engram-router hook"
say "...)\"', ya no hace nada dañino (engram-router ha desaparecido), pero"
say "puede borrarla si quiere dejar el fichero limpio."
say ""
say "Si durante la instalación retiró ENGRAM_CLOUD_* de su entorno, compruebe"
say "que ~/.engram/cloud.json tiene credenciales válidas antes de sincronizar:"
say ""
say "  engram cloud status"
say ""
say "Debe indicar 'Server source: cloud.json' y el servidor correcto."
