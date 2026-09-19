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

# Asks for one instance's directory, credentials and namespaces. Used both for
# a brand-new instance and for modifying one that already exists.
ask_one_instance() {
    local name="$1" cur_dir="${2:-}" cur_ns="${3:-}"

    local default_dir="${cur_dir:-$HOME/.local/share/engram-$name}" dir=""
    say "  Carpeta donde '$name' guardará su base de datos."
    say "  Pulse Enter para crear una nueva ahí, o escriba la ruta de una"
    say "  instalación de Engram que ya exista para reutilizar sus memorias."
    say "  Formato: ruta absoluta, o empezando por ~ (ej: ~/.engram)."
    while :; do
        dir=""
        read -r -p "  Carpeta [Enter = $default_dir]: " dir || dir=""
        dir="${dir:-$default_dir}"
        dir="${dir/#\~/$HOME}"
        # Caught early because mkdir would otherwise abort the whole install
        # several steps later, after credentials had already been typed.
        if [[ -e "$dir" && ! -d "$dir" ]]; then
            say "  '$dir' existe y no es una carpeta. Elija otra ruta."
            dir=""
            continue
        fi
        if [[ ! -e "$dir" ]]; then
            local parent="$dir"
            while [[ ! -e "$parent" && "$parent" != "/" ]]; do parent="$(dirname "$parent")"; done
            if [[ ! -w "$parent" ]]; then
                say "  No hay permiso de escritura en '$parent'. Elija otra ruta."
                dir=""
                continue
            fi
        fi
        break
    done

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
