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
chmod 0640 "$H3/.bashrc"
mode_before="$(stat -c %a "$H3/.bashrc")"
orig_content="$(cat "$H3/.bashrc")"
out3="$(run_offer "$H3" /bin/bash "s")"
assert_eq "mode is preserved (atomic mv keeps it sane)" "$mode_before" "$(stat -c %a "$H3/.bashrc" 2>/dev/null)"
assert_eq "no leftover *.engram-router.* temp file" "" "$(find "$H3" -maxdepth 1 -name '*.engram-router.*' 2>/dev/null)"

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
# 7b) Unwritable rc dir (mktemp/mv fail): non-fatal degrade, no truncation,
#     no leftover temp file, and the running shell survives under set -e.
# ===========================================================================
echo
echo "== answer 's' with an unwritable rc directory: non-fatal degrade =="
H9="$(new_fixture)"
printf 'export FOO=bar\n' > "$H9/.bashrc"
chmod 0444 "$H9/.bashrc"; chmod 0555 "$H9"
out9="$(export HOME="$H9" SHELL=/bin/bash
    source "$ROOT_DIR/install.sh" 2>/dev/null
    printf 's\n' | offer_shell_integration; printf 'SURVIVED=%d\n' "$?")"
chmod 0755 "$H9"
assert_match "unwritable dir: survives (non-fatal under set -e)" 'SURVIVED=0' "$out9"
assert_match "unwritable dir: Spanish failure message shown" 'No se pudo añadir' "$out9"
assert_eq "unwritable dir: rc file left byte-identical" "export FOO=bar" "$(cat "$H9/.bashrc")"
assert_eq "unwritable dir: no leftover temp file" "" "$(find "$H9" -maxdepth 1 -name '*.engram-router.*' 2>/dev/null)"

# ===========================================================================
# 7c) $rc_file is a symlink to a writable target elsewhere (Nix/home-manager/
#     chezmoi/stow layout): the symlink itself must never be replaced by the
#     atomic mv — only its target gets the marker block.
# ===========================================================================
echo
echo "== answer 's' with ~/.bashrc as a symlink to a writable target =="
Ha="$(new_fixture)"
mkdir -p "$Ha/real"
printf '# original real target\nexport BAR=baz\n' > "$Ha/real/target.sh"
ln -s "$Ha/real/target.sh" "$Ha/.bashrc"
link_before_a="$(readlink "$Ha/.bashrc")"
orig_target_a="$(cat "$Ha/real/target.sh")"
outA="$(run_offer "$Ha" /bin/bash "s")"
if [[ -L "$Ha/.bashrc" ]]; then _pass "symlink: ~/.bashrc is still a symlink after 's'"
else _fail "symlink: ~/.bashrc is still a symlink after 's'" "became: $(cat "$Ha/.bashrc" 2>/dev/null)"; fi
assert_eq "symlink: still points at the same target" "$link_before_a" "$(readlink "$Ha/.bashrc" 2>/dev/null)"
new_target_a="$(cat "$Ha/real/target.sh" 2>/dev/null || true)"
if [[ "$new_target_a" == "$orig_target_a"* ]]; then
    _pass "symlink: target's original content is preserved as a prefix"
else
    _fail "symlink: target's original content is preserved as a prefix" "got: $new_target_a"
fi
marker_count_a="$(grep -c 'engram-router hook bash' "$Ha/real/target.sh" 2>/dev/null || true)"
assert_eq "symlink: marker/eval line appears exactly once in the target" "1" "${marker_count_a:-0}"
backup_a="$(ls "$Ha"/real/target.sh.bak-engram-router-* 2>/dev/null | head -n1)"
if [[ -n "$backup_a" ]]; then
    _pass "symlink: backup sits next to the target"
    assert_eq "symlink: backup equals the original target content" "$orig_target_a" "$(cat "$backup_a")"
else
    _fail "symlink: backup sits next to the target" "none found"
    _fail "symlink: backup equals the original target content" "no backup to compare"
fi

# ===========================================================================
# 7d) $rc_file is a symlink to a read-only target in a read-only directory:
#     must degrade exactly like the unwritable-dir case, and the symlink
#     (and its target) must stay untouched.
# ===========================================================================
echo
echo "== answer 's' with ~/.bashrc as a symlink to a read-only target =="
Hb="$(new_fixture)"
mkdir -p "$Hb/rodir"
printf 'export RO=1\n' > "$Hb/rodir/target.sh"
chmod 0444 "$Hb/rodir/target.sh"
chmod 0555 "$Hb/rodir"
ln -s "$Hb/rodir/target.sh" "$Hb/.bashrc"
link_before_b="$(readlink "$Hb/.bashrc")"
orig_target_b="$(cat "$Hb/rodir/target.sh")"
outB="$(run_offer "$Hb" /bin/bash "s")"
chmod 0755 "$Hb/rodir"
assert_match "symlink to read-only target: degrades with the Spanish message" 'No se pudo añadir' "$outB"
if [[ -L "$Hb/.bashrc" ]]; then _pass "symlink to read-only target: ~/.bashrc is still a symlink"
else _fail "symlink to read-only target: ~/.bashrc is still a symlink" "became: $(cat "$Hb/.bashrc" 2>/dev/null)"; fi
assert_eq "symlink to read-only target: still points at the same target" "$link_before_b" "$(readlink "$Hb/.bashrc" 2>/dev/null)"
assert_eq "symlink to read-only target: target left byte-identical" "$orig_target_b" "$(cat "$Hb/rodir/target.sh")"

# ===========================================================================
# 7e) $rc_file is a dangling symlink (target's directory does not exist, so
#     "readlink -f" yields nothing): must degrade without creating anything.
# ===========================================================================
echo
echo "== answer 's' with ~/.bashrc as a dangling symlink =="
Hc="$(new_fixture)"
ln -s "$Hc/no-such-dir/target.sh" "$Hc/.bashrc"
link_before_c="$(readlink "$Hc/.bashrc")"
outC="$(run_offer "$Hc" /bin/bash "s")"
assert_match "dangling symlink: degrades with the Spanish message" 'No se pudo añadir' "$outC"
if [[ -L "$Hc/.bashrc" ]]; then _pass "dangling symlink: ~/.bashrc is still a symlink"
else _fail "dangling symlink: ~/.bashrc is still a symlink" "became: $(cat "$Hc/.bashrc" 2>/dev/null)"; fi
assert_eq "dangling symlink: still points at the same (missing) target" "$link_before_c" "$(readlink "$Hc/.bashrc" 2>/dev/null)"
if [[ -e "$Hc/no-such-dir" ]]; then
    _fail "dangling symlink: nothing is created" "found: $Hc/no-such-dir"
else
    _pass "dangling symlink: nothing is created"
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
