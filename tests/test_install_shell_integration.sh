#!/usr/bin/env bash
#
# tests/test_install_shell_integration.sh — offering to add the shell hook
# line to the user's rc file.
#
# install.sh used to only ever print the eval line and leave adding it to
# the user. Now, for a known shell ($SHELL basename is bash or zsh), it
# also asks ONE yes/no question (default No) and, on yes, appends exactly
# one marker-tagged eval line to that shell's rc file, after taking a
# timestamped backup. Any other/unknown shell keeps the old print-only
# behaviour exactly. See tests/test_install_shim_retirement.sh for the
# always-printed hook line and shim-retirement coverage, which this file
# does not duplicate.
#
# Test-safety (same convention as the other install tests): every call
# uses a fixture $HOME, and the real $HOME's dotfiles are snapshotted
# before and after to prove they are never touched.
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
# Real $HOME safety net (identical convention to the other install tests).
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -name 'engram@.service' 2>/dev/null
      local f
      for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" \
               "$HOME/.zshrc" "$HOME/.zprofile"; do
          [[ -e "$f" ]] && printf '%s\n' "$f"
      done
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

FIXTURES=()
trap 'rm -rf "${FIXTURES[@]}"' EXIT

new_fixture() {
    local d
    d="$(mktemp -d)"
    FIXTURES+=("$d")
    printf '%s' "$d"
}

# Sources install.sh (guarded by BASH_SOURCE, so main() never runs here) and
# calls offer_shell_integration directly with a fixture $HOME/$SHELL, so the
# installer's earlier interactive prompts never consume our piped stdin.
run_offer() {  # fixture_home shell answer
    local fixture_home="$1" shell="$2" answer="$3"
    (
        export HOME="$fixture_home"
        export SHELL="$shell"
        export ENGRAM_ROUTER_BIN="$fixture_home/.local/bin"
        export ENGRAM_ROUTER_LIB_DIR="$fixture_home/.local/lib/engram-router"
        export ENGRAM_ROUTER_CONFIG_DIR="$fixture_home/.config/engram-router"
        # shellcheck source=/dev/null
        source "$ROOT_DIR/install.sh" 2>/dev/null
        if [[ -z "$answer" ]]; then
            offer_shell_integration </dev/null
        else
            printf '%s\n' "$answer" | offer_shell_integration
        fi
    ) 2>&1
}

# ===========================================================================
# 1) Non-interactive stdin (no answer available): rc file untouched, both
#    the eval line and the question text are printed.
# ===========================================================================
echo "== non-interactive stdin: untouched, eval line and question printed =="
H1="$(new_fixture)"
out1="$(run_offer "$H1" /bin/bash "")"
if [[ -e "$H1/.bashrc" ]]; then
    _fail "non-interactive: ~/.bashrc stays untouched (or absent)" "found: $(cat "$H1/.bashrc")"
else
    _pass "non-interactive: ~/.bashrc stays untouched (or absent)"
fi
assert_match "non-interactive: eval line is printed" 'engram-router hook bash' "$out1"
assert_match "non-interactive: question text is printed" '¿Añado esta línea a ~/\.bashrc ahora\?' "$out1"

# ===========================================================================
# 2) Explicit "n": untouched.
# ===========================================================================
echo
echo "== answer 'n': untouched =="
H2="$(new_fixture)"
out2="$(run_offer "$H2" /bin/bash "n")"
if [[ -e "$H2/.bashrc" ]]; then
    _fail "answer n: ~/.bashrc stays untouched (or absent)" "found: $(cat "$H2/.bashrc")"
else
    _pass "answer n: ~/.bashrc stays untouched (or absent)"
fi
assert_match "answer n: eval line is still printed" 'engram-router hook bash' "$out2"

# ===========================================================================
# 3) Explicit "s" with an existing ~/.bashrc: original content preserved as
#    a prefix, marker block appended exactly once, timestamped backup
#    exists and equals the original.
# ===========================================================================
echo
echo "== answer 's' with an existing ~/.bashrc =="
H3="$(new_fixture)"
printf '# my existing bashrc\nexport FOO=bar\n' > "$H3/.bashrc"
orig_content="$(cat "$H3/.bashrc")"
out3="$(run_offer "$H3" /bin/bash "s")"

new_content="$(cat "$H3/.bashrc" 2>/dev/null || true)"
if [[ "$new_content" == "$orig_content"* ]]; then
    _pass "original content is preserved as a prefix"
else
    _fail "original content is preserved as a prefix" "got: $new_content"
fi

marker_count="$(grep -c 'engram-router hook bash' "$H3/.bashrc" 2>/dev/null || true)"
assert_eq "marker/eval line appears exactly once" "1" "${marker_count:-0}"
assert_match "output says the line was added" 'Añadid' "$out3"

backup_file="$(ls "$H3"/.bashrc.bak-engram-router-* 2>/dev/null | head -n1)"
if [[ -n "$backup_file" ]]; then
    _pass "a .bak-engram-router-* backup file exists"
    assert_eq "backup file equals the original content" "$orig_content" "$(cat "$backup_file")"
else
    _fail "a .bak-engram-router-* backup file exists" "none found"
    _fail "backup file equals the original content" "no backup to compare"
fi

# ===========================================================================
# 4) Asking again on the same (now-integrated) rc: not asked again, not
#    duplicated.
# ===========================================================================
echo
echo "== answer 's' again on an already-integrated rc =="
out4="$(run_offer "$H3" /bin/bash "s")"
marker_count2="$(grep -c 'engram-router hook bash' "$H3/.bashrc" 2>/dev/null || true)"
assert_eq "still exactly one marker/eval line after a second run" "1" "${marker_count2:-0}"
assert_not_match "no question is asked the second time" '¿Añado' "$out4"
assert_match "output says it is already there" 'ya (carga|está)' "$out4"

# ===========================================================================
# 5) Explicit "s" with no rc file: file is created containing the block.
# ===========================================================================
echo
echo "== answer 's' with no existing ~/.bashrc =="
H5="$(new_fixture)"
out5="$(run_offer "$H5" /bin/bash "s")"
if [[ -e "$H5/.bashrc" ]]; then
    _pass "~/.bashrc is created"
    assert_match "created file contains the eval line" 'engram-router hook bash' "$(cat "$H5/.bashrc")"
else
    _fail "~/.bashrc is created" "not found"
fi

# ===========================================================================
# 6) zsh: ~/.zshrc gets "hook zsh"; ~/.bashrc is left alone.
# ===========================================================================
echo
echo "== SHELL=zsh + answer 's' =="
H6="$(new_fixture)"
out6="$(run_offer "$H6" /usr/bin/zsh "s")"
if [[ -e "$H6/.zshrc" ]]; then
    _pass "~/.zshrc is created"
    assert_match "~/.zshrc contains the zsh hook line" 'engram-router hook zsh' "$(cat "$H6/.zshrc")"
else
    _fail "~/.zshrc is created" "not found"
fi
if [[ -e "$H6/.bashrc" ]]; then
    _fail "~/.bashrc is left untouched" "found: $(cat "$H6/.bashrc")"
else
    _pass "~/.bashrc is left untouched"
fi

# ===========================================================================
# 7) Unknown $SHELL: no question, both lines printed, nothing written.
# ===========================================================================
echo
echo "== unknown \$SHELL: no question, both lines printed, nothing written =="
H7="$(new_fixture)"
out7="$(run_offer "$H7" /bin/fish "")"
assert_match "unknown shell: bash line is printed" 'engram-router hook bash' "$out7"
assert_match "unknown shell: zsh line is printed" 'engram-router hook zsh' "$out7"
assert_not_match "unknown shell: no question is asked" '¿Añado' "$out7"
if [[ -e "$H7/.bashrc" || -e "$H7/.zshrc" ]]; then
    _fail "unknown shell: nothing is written" "found a dotfile"
else
    _pass "unknown shell: nothing is written"
fi

# ===========================================================================
# 8) real $HOME is untouched.
# ===========================================================================
echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's dotfiles are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
