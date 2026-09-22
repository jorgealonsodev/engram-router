# Inert Shell-Hook Routing

## Objective
Route each repository's Engram memories to the right instance (and therefore
the right Engram Cloud) without engram-router owning anything that belongs to
Engram or gentle-ai: no `engram` binary on PATH, no edits to MCP configs, no
edits to dotfiles.

## Problem
The router intercepts the *binary name* `engram` with a PATH shim at
`~/.local/bin/engram`. That name is owned by Homebrew and managed by
gentle-ai, which resolves `engram` through PATH and refuses when the resolved
executable is outside Homebrew paths. Measured on 2026-09-22 with the shim
installed:

- `gentle-ai update`  → `Update check incomplete: 1 tool(s) failed to check`
- `gentle-ai upgrade` → exit 1, `Error: update check failed for: engram`
- `gentle-ai doctor`  → `[!!] tool:engram ... 2 copies found in PATH`, status `degraded`

gentle-ai is the source of Engram and the channel for every update, so the
shim blocks Engram's own upgrade path. The shim also does not cover every
agent: gentle-ai writes the absolute Homebrew path into the Gemini and
Antigravity MCP configs, so those never reach the shim at all.

## Why this design
Engram documents `ENGRAM_DATA_DIR` as the data-directory override, and every
MCP child inherits the environment of the agent that spawned it (Engram's own
plugin template spawns with `stdio: 'inherit'` and no `env` of its own). So
the environment is the interception point that is *ours*; the binary name is
not. This is the pattern mise, direnv and nvm use: a shell hook that adjusts
the environment per directory, and nothing else.

Facts that fix the design (measured on Engram 2.0.0):
- `.engram/config.json` holds only `project_name`; no per-repo data dir.
- `cloud.json` holds exactly one `server_url` + `token` per data dir, so
  routing must select `ENGRAM_DATA_DIR`.
- A shell *function* named `engram` is invisible to other processes
  (gentle-ai is a Go binary using exec.LookPath), so the cloud-op refusal can
  live there without shadowing anything.

## Scope
IN: `engram-router hook <shell>` emitting the integration; retiring the PATH
shim from install, uninstall and doctor; doctor checks for the new invariants;
docs and tests.

OUT (recorded, not done): turning `~/.engram` into a cloud-less quarantine
instance and moving the personal cloud to a named instance. That would make
desktop-launched agents (which inherit no shell environment) fail closed too,
but it migrates live personal memories and needs its own explicit decision.
Until then, desktop-launched agents land in Engram's default `~/.engram`,
exactly as they do today.

## Constraints
- Never touch anything Engram or gentle-ai owns: the binary, its PATH entry,
  MCP configs, `gentle-ai sync` output.
- The installer never edits dotfiles (`install.sh:8`); the hook line is
  printed, the user adds it.
- Only a file carrying the `engram-router-shim` marker may ever be removed
  from `$PREFIX_BIN/engram`; a real binary there is never touched.
- Refusal policy is unchanged: unresolved routing refuses cloud operations
  (`sync`, `cloud`) and passes local operations through untouched.
- Artifacts, code comments and tests in English. User-facing CLI messages
  follow the existing convention of the file they live in (Spanish).
- TDD: strict (session config). Runner: `bash tests/<file>.sh`, plain bash
  asserts, `PASS`/`FAIL` counters, exit status `[[ $FAIL -eq 0 ]]`.
- Delivery: work-unit commits on `feat/inert-shell-hook-routing`, Conventional
  Commits, no AI attribution lines (user rule). Push/PR are the user's call.
  Forecast ~700 authored lines > 400: PR slicing strategy to be asked once
  when a PR is requested (`ask-on-risk`).
- RDD: on (global). After each work-unit commit run
  `gentle-ai review assess --cwd <repo> --base-ref <boundary> --committed-only --json`
  and follow the tier. First boundary: `58f8970`.

## Tasks
- [ ] T1 — `engram-router hook <bash|zsh>` emits shell integration.
      On every directory change (bash `PROMPT_COMMAND`, zsh `chpwd`) resolve
      routing for `$PWD` via `router_resolve`; export `ENGRAM_DATA_DIR` when
      resolved, unset it when not; cache by `$PWD` so the prompt does not pay
      `git` on every command. Define `engram()` that refuses cloud ops when the
      current directory is unresolved (same message policy as the shim) and
      otherwise runs `command engram "$@"`. Unknown shell → usage error.
      Tests: `tests/test_hook.sh` (fixture HOME + router.json; source the
      emitted code in a subshell; cd into a matched repo → `ENGRAM_DATA_DIR`
      set to that instance; cd into an unmatched dir → unset; `engram sync`
      refused when unresolved, exit 1, and the real binary never invoked (stub
      records calls); `type -P engram` still resolves the binary, proving the
      function shadows nothing on PATH).
      Route: delegated writer. Checks: `bash tests/test_hook.sh`,
      `bash tests/test_router.sh`.
- [ ] T2 — Retire the PATH shim.
      Delete `bin/engram`. `install.sh`: stop installing it; if
      `$PREFIX_BIN/engram` exists AND carries the `engram-router-shim` marker,
      remove it and say so; if it exists without the marker, leave it and warn.
      Replace `verify_path_precedence` with `verify_no_shadowing`: `engram`
      must resolve to something without the marker; print the hook line for
      the user's shell. `uninstall.sh`: remove `$PREFIX_BIN/engram` only with
      the marker. Tests: `tests/test_install_shim_retirement.sh` (fixture
      HOME: stale marker shim removed, foreign binary preserved with warning,
      no `engram` installed into `$PREFIX_BIN`).
      Route: delegated writer. Checks: new test, `bash tests/test_install_port.sh`.
- [ ] T3 — Doctor invariants.
      Replace `check_path_precedence` with `check_no_shadowing` (fail if
      `command -v engram` resolves to a marker file: "run the installer to
      remove the retired shim") and add `check_hook_active` (warn when the
      hook is not loaded: `ENGRAM_DATA_DIR` absent while the current repo
      resolves to an instance; ok when it matches; fail when it points at a
      different instance than routing says). Tests: `tests/test_doctor_hook.sh`.
      Route: delegated writer. Checks: new test, all existing tests.
- [ ] T4 — Docs and closure.
      README: replace the shim/PATH-precedence sections with the hook line,
      how inheritance reaches MCP children, what is not covered
      (desktop-launched agents), and the removed-shim upgrade note.
      `tests/test_engram_contract.sh` and `bin/engram-migrate` keep their
      marker-skipping resolution (still correct, now trivially so).
      Route: delegated writer. Checks: all tests; `bash -n` on every script.

## Acceptance
1. With the router installed, `gentle-ai update`, `gentle-ai upgrade` and
   `gentle-ai doctor` report `engram` as Homebrew-owned and up to date, from a
   non-interactive shell (no rc-file workaround involved).
2. From a hooked shell, `cd` into a work repo exports the work instance's
   `ENGRAM_DATA_DIR`; a personal repo exports the personal one; an unmatched
   dir exports nothing and `engram sync --cloud` is refused.
3. `~/.local/bin/engram` no longer exists after install; a leftover one from
   an earlier install is removed only if it carries the marker.
4. All tests pass.

## Progress
(evidence per task: commit id, checks observed, assessed RDD tier and outcome)
