#!/usr/bin/env bash
#
# tests/test_install_shim_retirement.sh — retiring the bin/engram PATH shim.
#
# Routing now happens through the shell hook (engram-router hook <shell>),
# not through a PATH shim named "engram". This file covers:
#   - install.sh no longer installs bin/engram, and bin/engram is gone from
#     the checkout entirely
#   - a stale marker-carrying $PREFIX_BIN/engram from an earlier install is
#     retired (removed) on the next install, with output saying so
#   - a foreign (non-marker) $PREFIX_BIN/engram is never touched, only warned
#     about
#   - verify_no_shadowing: OK when "engram" resolves to something without the
#     marker, FAIL when it resolves to a marker file
#   - the installer always prints the hook line for the user's $SHELL
#   - uninstall.sh mirrors the same marker-only removal rule
#
# Test-safety (same convention as tests/test_install_port.sh):
#   - every install.sh/uninstall.sh run uses a fixture $HOME, never the real one
#   - every run is wrapped in `timeout` and has ENGRAM_CLOUD_* scrubbed
#   - nothing here binds a real port or touches a real systemd unit
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
# Real $HOME safety net (identical to test_install_port.sh's).
# ---------------------------------------------------------------------------
_real_home_snapshot() {
    { find "$HOME/.config/engram-router" -type f 2>/dev/null
      find "$HOME/.local/bin" -maxdepth 1 -name 'engram*' 2>/dev/null
      find "$HOME/.local/lib/engram-router" -type f 2>/dev/null
      find "$HOME/.config/systemd/user" -maxdepth 1 -name 'engram@.service' 2>/dev/null
      # Mirrors install.sh's own DOTFILES_TO_SCAN, so "no dotfile is ever
      # edited" is actually defended by this snapshot instead of just the
      # engram-router-owned paths above.
      local f
      for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" \
               "$HOME/.zshrc" "$HOME/.zprofile"; do
          [[ -e "$f" ]] && printf '%s\n' "$f"
      done
    } | sort | xargs -r md5sum 2>/dev/null
}
REAL_HOME_BEFORE="$(_real_home_snapshot)"

run_install() {
    local fixture_home="$1"; shift
    (
        for v in $(compgen -e | grep '^ENGRAM_CLOUD_' || true); do unset "$v"; done
        export HOME="$fixture_home"
        export ENGRAM_ROUTER_BIN="$fixture_home/.local/bin"
        export ENGRAM_ROUTER_LIB_DIR="$fixture_home/.local/lib/engram-router"
        export ENGRAM_ROUTER_CONFIG_DIR="$fixture_home/.config/engram-router"
        timeout 30 bash "$ROOT_DIR/install.sh" "$@"
    )
}

run_uninstall() {
    local fixture_home="$1"; shift
    (
        export HOME="$fixture_home"
        export ENGRAM_ROUTER_BIN="$fixture_home/.local/bin"
        export ENGRAM_ROUTER_LIB_DIR="$fixture_home/.local/lib/engram-router"
        export ENGRAM_ROUTER_CONFIG_DIR="$fixture_home/.config/engram-router"
        timeout 30 bash "$ROOT_DIR/uninstall.sh" "$@"
    )
}

# ===========================================================================
# 1) bin/engram is gone from the checkout entirely.
# ===========================================================================
echo "== bin/engram is retired from the checkout =="
if [[ -e "$ROOT_DIR/bin/engram" ]]; then
    _fail "bin/engram no longer exists in the checkout" "found at $ROOT_DIR/bin/engram"
else
    _pass "bin/engram no longer exists in the checkout"
fi

echo
echo "== install.sh no longer references installing bin/engram =="
if grep -q 'bin/engram"' "$ROOT_DIR/install.sh" 2>/dev/null; then
    _fail "install.sh has no 'install ... bin/engram' line" "grep found a match"
else
    _pass "install.sh has no 'install ... bin/engram' line"
fi

# ===========================================================================
# 2) Fresh install: no shim installed, the four namespaced tools are.
# ===========================================================================
FIXTURE1="$(mktemp -d)"
mkdir -p "$FIXTURE1/home"
trap_cleanup() { rm -rf "$FIXTURE1" "${FIXTURE2:-}" "${FIXTURE3:-}" "${FIXTURE_SYM:-}" "${FIXTURE4:-}" "${FIXTURE5:-}" "${FIXTURE6:-}"; }
trap trap_cleanup EXIT

BIN1="$FIXTURE1/home/.local/bin"

echo
echo "== fresh install: no PATH shim, all four namespaced tools present =="
out1="$(run_install "$FIXTURE1/home" </dev/null 2>&1)"
if [[ -e "$BIN1/engram" ]]; then
    _fail "\$PREFIX_BIN/engram does NOT exist after a fresh install" "found at $BIN1/engram"
else
    _pass "\$PREFIX_BIN/engram does NOT exist after a fresh install"
fi
for tool in engram-router engram-doctor engram-migrate; do
    if [[ -x "$BIN1/$tool" ]]; then _pass "$tool is installed"
    else _fail "$tool is installed" "not found at $BIN1/$tool"; fi
done
if [[ -L "$BIN1/engram-where" ]]; then _pass "engram-where symlink is installed"
else _fail "engram-where symlink is installed" "not found at $BIN1/engram-where"; fi

# ===========================================================================
# 3) Stale marker shim from an earlier install is retired.
# ===========================================================================
FIXTURE2="$(mktemp -d)"
mkdir -p "$FIXTURE2/home/.local/bin"
BIN2="$FIXTURE2/home/.local/bin"
cat > "$BIN2/engram" <<'EOF'
#!/usr/bin/env bash
# engram-router-shim: identifies this file to the other tools.
echo "stale shim"
EOF
chmod 0755 "$BIN2/engram"

echo
echo "== a pre-existing marker shim is removed on install, and announced =="
out2="$(run_install "$FIXTURE2/home" </dev/null 2>&1)"
if [[ -e "$BIN2/engram" ]]; then
    _fail "marker shim is removed" "still present at $BIN2/engram"
else
    _pass "marker shim is removed"
fi
assert_match "output announces the shim retirement" \
    'shim antiguo|retirad' "$out2"

# ===========================================================================
# 4) Foreign (non-marker) $PREFIX_BIN/engram is preserved, byte-identical.
# ===========================================================================
FIXTURE3="$(mktemp -d)"
mkdir -p "$FIXTURE3/home/.local/bin"
BIN3="$FIXTURE3/home/.local/bin"
cat > "$BIN3/engram" <<'EOF'
#!/usr/bin/env bash
# a completely unrelated script that happens to be named "engram"
echo "not ours"
EOF
chmod 0755 "$BIN3/engram"
foreign_sum_before="$(md5sum "$BIN3/engram")"

echo
echo "== a foreign (non-marker) \$PREFIX_BIN/engram is left untouched, with a warning =="
out3="$(run_install "$FIXTURE3/home" </dev/null 2>&1)"
if [[ -e "$BIN3/engram" ]]; then
    _pass "foreign engram file still exists"
    foreign_sum_after="$(md5sum "$BIN3/engram")"
    assert_eq "foreign engram file is byte-identical" "$foreign_sum_before" "$foreign_sum_after"
else
    _fail "foreign engram file still exists" "removed"
    _fail "foreign engram file is byte-identical" "removed"
fi
assert_match "output warns that the foreign file is not ours" \
    'no es nuestro|ajeno|no pertenece' "$out3"

# ===========================================================================
# 4b) symlink at $PREFIX_BIN/engram: marker target -> symlink removed only;
#     foreign target -> left alone, warns it shadows engram.
# ===========================================================================
FIXTURE_SYM="$(mktemp -d)"
mkdir -p "$FIXTURE_SYM/home/.local/bin"
BIN_SYM="$FIXTURE_SYM/home/.local/bin"
cat > "$FIXTURE_SYM/home/.local/marker-target" <<'EOF'
#!/usr/bin/env bash
# engram-router-shim: identifies this file to the other tools.
echo "stale shim via symlink"
EOF
chmod 0755 "$FIXTURE_SYM/home/.local/marker-target"
ln -s "$FIXTURE_SYM/home/.local/marker-target" "$BIN_SYM/engram"
sum_before="$(md5sum "$FIXTURE_SYM/home/.local/marker-target")"

echo
echo "== symlink -> marker file: symlink removed, target untouched =="
out_sym="$(run_install "$FIXTURE_SYM/home" </dev/null 2>&1)"
if [[ -e "$BIN_SYM/engram" ]]; then _fail "symlink to marker file is removed" "still present"
else _pass "symlink to marker file is removed"; fi
assert_eq "marker target is byte-identical" "$sum_before" "$(md5sum "$FIXTURE_SYM/home/.local/marker-target")"
assert_match "output announces the symlink removal" \
    'Retirado el enlace simbólico' "$out_sym"

FOREIGN_TGT="$FIXTURE_SYM/home/.local/foreign-target"
printf '#!/usr/bin/env bash\necho unrelated\n' > "$FOREIGN_TGT"
chmod 0755 "$FOREIGN_TGT"; ln -sf "$FOREIGN_TGT" "$BIN_SYM/engram"
out_sym2="$(run_install "$FIXTURE_SYM/home" </dev/null 2>&1)"
if [[ -L "$BIN_SYM/engram" ]]; then _pass "symlink to foreign target still exists"
else _fail "symlink to foreign target still exists" "removed"; fi
assert_eq "symlink target is unchanged" "$FOREIGN_TGT" "$(readlink "$BIN_SYM/engram")"
assert_match "output warns it keeps shadowing engram" 'ensombrec' "$out_sym2"
rm -rf "$FIXTURE_SYM"

# ===========================================================================
# 5) verify_no_shadowing: function-level tests via sourcing install.sh.
# ===========================================================================
echo
echo "== verify_no_shadowing: function-level behaviour =="
FIXTURE4="$(mktemp -d)"
mkdir -p "$FIXTURE4/realbin" "$FIXTURE4/shimbin"

# A stub "real" engram (no marker).
cat > "$FIXTURE4/realbin/engram" <<'EOF'
#!/usr/bin/env bash
echo "real engram $*"
EOF
chmod 0755 "$FIXTURE4/realbin/engram"

# A marker-carrying leftover shim.
cat > "$FIXTURE4/shimbin/engram" <<'EOF'
#!/usr/bin/env bash
# engram-router-shim: identifies this file to the other tools.
echo "stale shim $*"
EOF
chmod 0755 "$FIXTURE4/shimbin/engram"

verify_no_shadowing_output() {
    local path_prefix="$1"
    (
        PREFIX_BIN="$FIXTURE4/prefixbin"
        mkdir -p "$PREFIX_BIN"
        export PATH="$path_prefix:$PATH"
        # shellcheck source=/dev/null
        source "$ROOT_DIR/install.sh" 2>/dev/null
        verify_no_shadowing
    ) 2>&1
}

out_real="$(verify_no_shadowing_output "$FIXTURE4/realbin")"
rc_real=$?
assert_match "resolving to a non-marker binary reports nothing shadows it" \
    'resuelve al binario real|nada lo ensombra' "$out_real"
assert_eq "resolving to a non-marker binary returns success" "0" "$rc_real"

out_shim="$(verify_no_shadowing_output "$FIXTURE4/shimbin")"
rc_shim=$?
assert_match "resolving to a marker file reports the retired-shim failure" \
    'shim retirado' "$out_shim"
assert_eq "resolving to a marker file returns failure" "1" "$rc_shim"

# ===========================================================================
# 6) Hook instructions are always printed, chosen from $SHELL.
# ===========================================================================
FIXTURE5="$(mktemp -d)"
mkdir -p "$FIXTURE5/home"

echo
echo "== hook instructions are printed, matching \$SHELL =="
out_bash="$(SHELL=/bin/bash run_install "$FIXTURE5/home" </dev/null 2>&1)"
assert_match "SHELL=/bin/bash prints the bash hook line" \
    'engram-router hook bash' "$out_bash"
assert_not_match "SHELL=/bin/bash does not print the zsh hook line" \
    'engram-router hook zsh' "$out_bash"

FIXTURE6="$(mktemp -d)"
mkdir -p "$FIXTURE6/home"
out_zsh="$(SHELL=/usr/bin/zsh run_install "$FIXTURE6/home" </dev/null 2>&1)"
assert_match "SHELL=/usr/bin/zsh prints the zsh hook line" \
    'engram-router hook zsh' "$out_zsh"

# ===========================================================================
# 7) uninstall.sh: marker removed, foreign preserved.
# ===========================================================================
echo
echo "== uninstall.sh: marker shim removed =="
FIXTURE_U1="$(mktemp -d)"
mkdir -p "$FIXTURE_U1/home/.local/bin"
cat > "$FIXTURE_U1/home/.local/bin/engram" <<'EOF'
#!/usr/bin/env bash
# engram-router-shim: identifies this file to the other tools.
echo "stale shim"
EOF
chmod 0755 "$FIXTURE_U1/home/.local/bin/engram"
uninstall_out1="$(run_uninstall "$FIXTURE_U1/home" --yes </dev/null 2>&1)"
if [[ -e "$FIXTURE_U1/home/.local/bin/engram" ]]; then
    _fail "uninstall removes a marker-carrying \$PREFIX_BIN/engram" "still present"
else
    _pass "uninstall removes a marker-carrying \$PREFIX_BIN/engram"
fi
rm -rf "$FIXTURE_U1"

echo
echo "== uninstall.sh: foreign engram preserved with a message =="
FIXTURE_U2="$(mktemp -d)"
mkdir -p "$FIXTURE_U2/home/.local/bin"
cat > "$FIXTURE_U2/home/.local/bin/engram" <<'EOF'
#!/usr/bin/env bash
echo "not ours"
EOF
chmod 0755 "$FIXTURE_U2/home/.local/bin/engram"
foreign_u_sum_before="$(md5sum "$FIXTURE_U2/home/.local/bin/engram")"
uninstall_out2="$(run_uninstall "$FIXTURE_U2/home" --yes </dev/null 2>&1)"
if [[ -e "$FIXTURE_U2/home/.local/bin/engram" ]]; then
    _pass "uninstall preserves a foreign \$PREFIX_BIN/engram"
    foreign_u_sum_after="$(md5sum "$FIXTURE_U2/home/.local/bin/engram")"
    assert_eq "preserved foreign engram file is byte-identical" \
        "$foreign_u_sum_before" "$foreign_u_sum_after"
else
    _fail "uninstall preserves a foreign \$PREFIX_BIN/engram" "removed"
    _fail "preserved foreign engram file is byte-identical" "removed"
fi
assert_match "uninstall output warns the foreign file is not ours" \
    'no es nuestro|ajeno|no pertenece' "$uninstall_out2"
rm -rf "$FIXTURE_U2"

echo
echo "== uninstall.sh closing message mentions the hook line is now optional =="
FIXTURE_U3="$(mktemp -d)"
mkdir -p "$FIXTURE_U3/home"
uninstall_out3="$(run_uninstall "$FIXTURE_U3/home" --yes </dev/null 2>&1)"
assert_match "uninstall mentions the 'engram-router hook' line can be removed" \
    'engram-router hook' "$uninstall_out3"
rm -rf "$FIXTURE_U3"

# ===========================================================================
# 8) real $HOME is untouched.
# ===========================================================================
echo
echo "== real \$HOME is untouched =="
REAL_HOME_AFTER="$(_real_home_snapshot)"
assert_eq "real \$HOME's engram-router files are byte-identical before/after" \
    "$REAL_HOME_BEFORE" "$REAL_HOME_AFTER"

echo
echo "pasadas: $PASS · fallidas: $FAIL"
[[ $FAIL -eq 0 ]]
