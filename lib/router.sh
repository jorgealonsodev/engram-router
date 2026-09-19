#!/usr/bin/env bash
# lib/router.sh — shared logic for the Engram multi-cloud router.
#
# Provides:
#   router_normalize_remote <remote-url>   -> prints "host[:port]/owner"
#   router_load_config <config-file>       -> populates RULE_* / INSTANCE_* arrays
#   router_match_instance <normalized>     -> prints matched instance name
#   router_read_repo_override <repo-dir>   -> prints "instance" value from
#                                              <repo-dir>/.engram/config.json
#                                              if present
#   router_resolve <repo-dir> <config-file> -> populates ROUTER_* globals with
#                                              the full resolution result
#
# No dependency beyond bash builtins. Deliberately avoids jq/python so the
# shim keeps working on a bare colleague machine (coreutils/git/systemd only).
#
# This file is meant to be sourced, not executed.
#
# shellcheck disable=SC2034
# (INSTANCE_PORT, INSTANCE_AUTOSYNC, ROUTER_SOURCE, ROUTER_MATCHED_RULE,
# ROUTER_DATA_DIR and friends are part of this library's output contract —
# they are read by callers such as bin/engram, bin/engram-router and
# bin/engram-doctor after sourcing this file, not by router.sh itself.)

# ---------------------------------------------------------------------------
# Remote URL normalization
# ---------------------------------------------------------------------------

# router_normalize_remote REMOTE
#
# Normalizes a git remote URL to a comparable "host[:port]/owner" string.
# Handles, per the audited remote forms in odd/tasks/engram-multi-cloud-router.md:
#   - SCP syntax:            git@github.com:owner/repo.git
#   - URL syntax:             https://github.com/owner/repo.git
#   - ssh:// with explicit port: ssh://git@host:4433/owner/repo.git
#   - SCP syntax WITH a non-standard port glued to the path:
#       host:4433/owner/repo.git   (looks like "host:path" but the first path
#       segment is actually a port number — a naive split on the first ":"
#       breaks this, so we peel off a leading "<digits>/" from the SCP path)
#   - the "git::@host/owner/repo" prefix some plugin managers add
router_normalize_remote() {
    local remote="$1"
    local host="" port="" path=""

    # Odd plugin-manager prefix: strip it before anything else.
    remote="${remote#git::@}"

    if [[ "$remote" =~ ^(ssh|git|https?)://([^@/]+@)?([^/:]+)(:([0-9]+))?/(.+)$ ]]; then
        host="${BASH_REMATCH[3]}"
        port="${BASH_REMATCH[5]}"
        path="${BASH_REMATCH[6]}"
    elif [[ "$remote" =~ ^([^@/]+@)?([^/:]+):(.+)$ ]]; then
        # SCP-like syntax: [user@]host:path
        host="${BASH_REMATCH[2]}"
        local rest="${BASH_REMATCH[3]}"
        # Disambiguate "host:4433/owner/repo" (port glued onto the SCP path)
        # from ordinary "host:owner/repo" (no port at all).
        if [[ "$rest" =~ ^([0-9]+)/(.+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            path="${BASH_REMATCH[2]}"
        else
            path="$rest"
        fi
    elif [[ "$remote" =~ ^([^@/:]+)/(.+)$ ]]; then
        # Bare "host/owner/repo" with no scheme and no colon at all
        # (this is what remains of "git::@github.com/owner/repo" once the
        # prefix above is stripped).
        host="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    [[ -z "$host" || -z "$path" ]] && return 1

    host="${host,,}" # lowercase for comparability
    path="${path%.git}"
    path="${path%/}"
    local owner="${path%%/*}"
    [[ -z "$owner" ]] && return 1

    if [[ -n "$port" ]]; then
        printf '%s:%s/%s\n' "$host" "$port" "$owner"
    else
        printf '%s/%s\n' "$host" "$owner"
    fi
}

# router_repo_remote REPO_DIR [REMOTE_NAME]
# Prints the raw remote URL for a repo directory (default remote "origin").
router_repo_remote() {
    local repo_dir="$1" remote_name="${2:-origin}"
    git -C "$repo_dir" remote get-url "$remote_name" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Minimal JSON reader (only what the router config / .engram/config.json need)
# ---------------------------------------------------------------------------
# Deliberately hand-rolled: no jq dependency, and the schema is small and
# fully controlled by this project (flat objects, no nested arrays/objects
# beyond the two levels the router config uses).

# _router_json_index_after HAYSTACK NEEDLE
# Prints the character index right after the first occurrence of NEEDLE in
# HAYSTACK, or nothing if not found.
_router_json_index_after() {
    local haystack="$1" needle="$2" before
    before="${haystack%%"$needle"*}"
    [[ "$before" == "$haystack" ]] && return 1
    printf '%s\n' "$(( ${#before} + ${#needle} ))"
}

# _router_json_parse_flat_object STRING START_INDEX OUT_ARRAY_NAME
# Parses a flat JSON object (string/number/bool values only, no nesting)
# starting at the "{" found at/after START_INDEX. Fills the caller-provided
# associative array with key -> value. Sets _ROUTER_JSON_END to the index
# right after the closing "}".
_router_json_parse_flat_object() {
    local s="$1" i="$2"
    local -n _out="$3"
    local n=${#s} c key val

    while (( i < n )) && [[ "${s:$i:1}" != "{" ]]; do ((i++)); done
    (( i >= n )) && return 1
    ((i++))

    while :; do
        while (( i < n )) && [[ "${s:$i:1}" =~ [[:space:],] ]]; do ((i++)); done
        (( i >= n )) && return 1
        c="${s:$i:1}"
        if [[ "$c" == "}" ]]; then
            ((i++))
            break
        fi
        [[ "$c" == '"' ]] || return 1
        ((i++))
        key=""
        while (( i < n )) && [[ "${s:$i:1}" != '"' ]]; do
            key+="${s:$i:1}"
            ((i++))
        done
        ((i++)) # closing quote of key

        while (( i < n )) && [[ "${s:$i:1}" =~ [[:space:]:] ]]; do ((i++)); done
        c="${s:$i:1}"
        if [[ "$c" == '"' ]]; then
            ((i++))
            val=""
            while (( i < n )) && [[ "${s:$i:1}" != '"' ]]; do
                val+="${s:$i:1}"
                ((i++))
            done
            ((i++)) # closing quote of value
        else
            val=""
            while (( i < n )) && [[ "${s:$i:1}" != "," && "${s:$i:1}" != "}" && ! "${s:$i:1}" =~ [[:space:]] ]]; do
                val+="${s:$i:1}"
                ((i++))
            done
        fi
        _out["$key"]="$val"
    done
    _ROUTER_JSON_END=$i
}

# _router_json_parse_rules_array STRING START_INDEX
# Fills RULE_PREFIXES / RULE_INSTANCES (indexed, order preserved) from a
# JSON array of {"prefix": "...", "instance": "..."} objects.
_router_json_parse_rules_array() {
    local s="$1" i="$2" c
    local n=${#s}
    RULE_PREFIXES=()
    RULE_INSTANCES=()

    while (( i < n )) && [[ "${s:$i:1}" != "[" ]]; do ((i++)); done
    (( i >= n )) && return 1
    ((i++))

    while :; do
        while (( i < n )) && [[ "${s:$i:1}" =~ [[:space:],] ]]; do ((i++)); done
        (( i >= n )) && return 1
        c="${s:$i:1}"
        if [[ "$c" == "]" ]]; then
            ((i++))
            break
        fi
        [[ "$c" == "{" ]] || return 1
        local -A obj=()
        _router_json_parse_flat_object "$s" "$i" obj || return 1
        i=$_ROUTER_JSON_END
        RULE_PREFIXES+=("${obj[prefix]:-}")
        RULE_INSTANCES+=("${obj[instance]:-}")
    done
    _ROUTER_JSON_END=$i
}

# _router_json_parse_instances_object STRING START_INDEX
# Fills INSTANCE_NAMES (indexed) and INSTANCE_DATA_DIR / INSTANCE_PORT /
# INSTANCE_AUTOSYNC (associative, keyed by instance name).
_router_json_parse_instances_object() {
    local s="$1" i="$2" c
    local n=${#s}
    INSTANCE_NAMES=()
    declare -gA INSTANCE_DATA_DIR=()
    declare -gA INSTANCE_PORT=()
    declare -gA INSTANCE_AUTOSYNC=()

    while (( i < n )) && [[ "${s:$i:1}" != "{" ]]; do ((i++)); done
    (( i >= n )) && return 1
    ((i++))

    while :; do
        while (( i < n )) && [[ "${s:$i:1}" =~ [[:space:],] ]]; do ((i++)); done
        (( i >= n )) && return 1
        c="${s:$i:1}"
        if [[ "$c" == "}" ]]; then
            ((i++))
            break
        fi
        [[ "$c" == '"' ]] || return 1
        ((i++))
        local name=""
        while (( i < n )) && [[ "${s:$i:1}" != '"' ]]; do
            name+="${s:$i:1}"
            ((i++))
        done
        ((i++))
        while (( i < n )) && [[ "${s:$i:1}" =~ [[:space:]:] ]]; do ((i++)); done

        local -A obj=()
        _router_json_parse_flat_object "$s" "$i" obj || return 1
        i=$_ROUTER_JSON_END

        INSTANCE_NAMES+=("$name")
        INSTANCE_DATA_DIR["$name"]="${obj[data_dir]:-}"
        INSTANCE_PORT["$name"]="${obj[port]:-}"
        INSTANCE_AUTOSYNC["$name"]="${obj[autosync]:-false}"
    done
}

# router_expand_path VALUE
# Expands a literal leading "$HOME" token or "~" in a config-supplied path.
# Deliberately NOT a general eval — only these two well-known forms are
# substituted, to avoid arbitrary code execution from a config file.
router_expand_path() {
    local v="$1"
    # Matching literal "$HOME"/"~" text from the config file, not expanding
    # a shell variable — the single-quoted patterns below are intentional.
    # shellcheck disable=SC2016,SC2088
    case "$v" in
        '$HOME'/*) v="${HOME}${v#\$HOME}" ;;
        '~/'*) v="${HOME}/${v#\~/}" ;;
        '~') v="${HOME}" ;;
    esac
    printf '%s\n' "$v"
}

# router_load_config CONFIG_FILE
# Populates RULE_PREFIXES/RULE_INSTANCES (ordered) and INSTANCE_NAMES /
# INSTANCE_DATA_DIR / INSTANCE_PORT / INSTANCE_AUTOSYNC from a router config
# JSON file. Rules keep file order: matching is first-match-wins.
router_load_config() {
    local file="$1" content idx
    [[ -r "$file" ]] || { echo "router: cannot read config file: $file" >&2; return 1; }
    content="$(cat "$file")"

    RULE_PREFIXES=()
    RULE_INSTANCES=()
    INSTANCE_NAMES=()
    declare -gA INSTANCE_DATA_DIR=()
    declare -gA INSTANCE_PORT=()
    declare -gA INSTANCE_AUTOSYNC=()

    if idx="$(_router_json_index_after "$content" '"rules"')"; then
        _router_json_parse_rules_array "$content" "$idx" || {
            echo "router: malformed \"rules\" in $file" >&2
            return 1
        }
    fi
    if idx="$(_router_json_index_after "$content" '"instances"')"; then
        _router_json_parse_instances_object "$content" "$idx" || {
            echo "router: malformed \"instances\" in $file" >&2
            return 1
        }
    fi
}

# router_read_repo_override REPO_DIR
# Prints the "instance" value from REPO_DIR/.engram/config.json if that key
# is present (this file already exists in Engram with "project_name"; we
# reuse it rather than inventing a new marker file). Empty output + failure
# if the file or the key is absent.
router_read_repo_override() {
    local repo_dir="$1" content
    local marker="$repo_dir/.engram/config.json"
    [[ -r "$marker" ]] || return 1
    content="$(cat "$marker")"
    local -A obj=()
    _router_json_parse_flat_object "$content" 0 obj || return 1
    local val="${obj[instance]:-}"
    [[ -n "$val" ]] || return 1
    printf '%s\n' "$val"
}

# ---------------------------------------------------------------------------
# Rule matching
# ---------------------------------------------------------------------------

# router_match_instance NORMALIZED
# First-match-wins, prefix-based, evaluated in RULE_PREFIXES file order.
# A rule prefix matches when NORMALIZED equals it exactly, or NORMALIZED
# starts with "<prefix>/" (boundary-aware, so "github.com/Enfo" can never
# accidentally match "github.com/your-org").
router_match_instance() {
    local normalized="$1" i prefix
    for i in "${!RULE_PREFIXES[@]}"; do
        prefix="${RULE_PREFIXES[$i]}"
        [[ -z "$prefix" ]] && continue
        if [[ "$normalized" == "$prefix" || "$normalized" == "$prefix"/* ]]; then
            printf '%s\n' "${RULE_INSTANCES[$i]}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Full resolution
# ---------------------------------------------------------------------------

# router_resolve REPO_DIR CONFIG_FILE
#
# Populates:
#   ROUTER_REMOTE      raw remote URL, or "" if none
#   ROUTER_NORMALIZED  normalized host[:port]/owner form, or "" if unparseable
#   ROUTER_SOURCE      "override" | "rule" | "unmatched"
#   ROUTER_MATCHED_RULE  the matched rule prefix, or "" for override/unmatched
#   ROUTER_INSTANCE    resolved instance name, or "" if unmatched
#   ROUTER_DATA_DIR    resolved instance's data dir (already ~/$HOME-expanded),
#                       or "" if unmatched
#
# Resolution order (per the feature spec): repo-level .engram/config.json
# "instance" override > rule match > unmatched.
router_resolve() {
    local repo_dir="$1" config_file="$2"

    ROUTER_REMOTE=""
    ROUTER_NORMALIZED=""
    ROUTER_SOURCE="unmatched"
    ROUTER_MATCHED_RULE=""
    ROUTER_INSTANCE=""
    ROUTER_DATA_DIR=""

    router_load_config "$config_file" || return 1

    ROUTER_REMOTE="$(router_repo_remote "$repo_dir" 2>/dev/null || true)"
    if [[ -n "$ROUTER_REMOTE" ]]; then
        ROUTER_NORMALIZED="$(router_normalize_remote "$ROUTER_REMOTE" 2>/dev/null || true)"
    fi

    local override
    if override="$(router_read_repo_override "$repo_dir" 2>/dev/null)"; then
        ROUTER_SOURCE="override"
        ROUTER_INSTANCE="$override"
    elif [[ -n "$ROUTER_NORMALIZED" ]]; then
        local matched
        if matched="$(router_match_instance "$ROUTER_NORMALIZED")"; then
            ROUTER_SOURCE="rule"
            ROUTER_INSTANCE="$matched"
            ROUTER_MATCHED_RULE="$ROUTER_NORMALIZED"
            # Recover which literal rule prefix matched for reporting.
            local i prefix
            for i in "${!RULE_PREFIXES[@]}"; do
                prefix="${RULE_PREFIXES[$i]}"
                [[ -z "$prefix" ]] && continue
                if [[ "$ROUTER_NORMALIZED" == "$prefix" || "$ROUTER_NORMALIZED" == "$prefix"/* ]]; then
                    ROUTER_MATCHED_RULE="$prefix"
                    break
                fi
            done
        fi
    fi

    if [[ -n "$ROUTER_INSTANCE" && -n "${INSTANCE_DATA_DIR[$ROUTER_INSTANCE]:-}" ]]; then
        ROUTER_DATA_DIR="$(router_expand_path "${INSTANCE_DATA_DIR[$ROUTER_INSTANCE]}")"
    fi
}

# router_is_cloud_op ARG1
# True when the first engram sub-command argument is a cloud operation that
# must be refused when routing is unresolved.
router_is_cloud_op() {
    case "$1" in
        sync|cloud) return 0 ;;
        *) return 1 ;;
    esac
}
