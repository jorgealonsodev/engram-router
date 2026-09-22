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
- [x] T1 — `engram-router hook <bash|zsh>` emits shell integration.
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
- [x] T2 — Retire the PATH shim.
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
- [x] T3 — Doctor invariants.
      Replace `check_path_precedence` with `check_no_shadowing` (fail if
      `command -v engram` resolves to a marker file: "run the installer to
      remove the retired shim") and add `check_hook_active` (warn when the
      hook is not loaded: `ENGRAM_DATA_DIR` absent while the current repo
      resolves to an instance; ok when it matches; fail when it points at a
      different instance than routing says). Tests: `tests/test_doctor_hook.sh`.
      Route: delegated writer. Checks: new test, all existing tests.
- [x] T4 — Docs and closure.
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

- T1 — commit `c9f047f`. Route: delegated writer (sonnet); trigger: 2 non-trivial
  files. TDD observed: RED 13/24 passed → GREEN 24/24 → REFACTOR 24/24.
  Checks: `bash tests/test_hook.sh` 24/24; `bash tests/test_router.sh` 42/42;
  `bash -n bin/engram-router` ok; `bash -n <(hook bash)` ok; `zsh -n <(hook zsh)`
  ok (zsh 5.9 present, functional smoke test too). Parent spot check re-ran
  both test files: identical. RDD assess: high (`shell_process` in the test).
  Native review: consent granted by the user; lineage created with four lenses;
  all four provider-issued `capture-result` slots refused at preflight
  (`invalid_request`: tokens carry neither `--agent` nor `--input`); exact
  STATUS re-query reoffered identical tokens. Equivalent open defect found:
  Gentleman-Programming/gentle-ai#4804 (3.4.0 stable, same shape); one
  occurrence comment posted, no labels touched. Candidate-scoped decline run
  once and validated (`declined_this_candidate`). Verification of record for
  this task therefore follows the RDD-off tier (high): writer self-verification
  above plus an independent verifier. Independent verifier (sonnet, read-only,
  clean worktree of c9f047f): tests reproduce 24/24 and 42/42; adversarial
  read found no functional defect; verdict pass-with-notes. Notes (all low,
  folded into T4): the `type -P` half of the "shadows nothing on PATH" test is
  vacuous (bash's `type -P` always bypasses functions; the child-shell
  `command -v` half is the discriminating one and passes); the `$PWD` cache
  leaves `ENGRAM_DATA_DIR` stale if `router.json` changes while parked in the
  same directory (document it); the suite calls the hook manually rather than
  letting `PROMPT_COMMAND`/`chpwd` fire (verifier confirmed automatic firing
  and re-eval dedup by hand in real bash and zsh). T1 checked off.
- T2 — commit `2cf16d8` (amended once locally: the first `git add` aborted on the
  already-staged deletion and left only `bin/engram` in the commit). Route:
  delegated writer (sonnet); trigger: 3 non-trivial files. TDD observed: RED
  8/25 → GREEN 25/25. Checks: `bash tests/test_install_shim_retirement.sh`
  25/25; `bash tests/test_install_port.sh` 10/10; `bash tests/test_hook.sh`
  24/24; `bash tests/test_router.sh` 42/42; `bash tests/test_engram_contract.sh`
  19/19; `bash tests/test_migrate_source_pull.sh` 29/29; `bash -n install.sh`
  and `uninstall.sh` ok; no `bin/engram"` install line left. Parent spot check
  re-ran the new test and `test_install_port.sh`: identical; read the three new
  installer functions and the uninstall gate. RDD assess from the boundary
  58f8970: high (`executable_mode` on the deleted shim, `shell_process` in
  install.sh). Native preflight entered through the canonical STATUS with
  `--agent claude-code`, scoped to this commit (`--base-ref c9f047f`). This
  path yields capture tokens that carry `--agent` (unlike the assess-derived
  path used for T1; noted as evidence on gentle-ai#4804). Consent granted by
  the user; lineage review-bd9dd5fe3ff65f27, four lenses. `review-risk`,
  `review-resilience` and `review-readability` admitted; `review-reliability`
  refused twice by the model provider's safeguards on the reviewer transport
  (API error, not a gentle-ai defect; no report). Exact STATUS re-query
  reoffered the identical slot; one relaunch, same refusal; no further retry.
  User chose to decline this candidate: exact decline run once and validated
  (`declined_this_candidate`). Verification of record follows the RDD-off
  tier (high): writer self-verification above plus an independent verifier.
  Independent verifier (sonnet, read-only, clean worktree of 2cf16d8): full
  suite reproduced (25/25, 10/10, 24/24, 42/42, 19/19, 29/29; `bash -n` ok);
  adversarial read found no correctness or safety defect; verdict
  pass-with-notes. Notes (low, folded into T4): a symlink at
  `$PREFIX_BIN/engram` is correctly left alone but not reported;
  `_real_home_snapshot` in the new test does not cover the scanned dotfiles.
  T2 checked off.
- T3 — commit `0e34ac3`. Route: delegated writer (sonnet); trigger: 2
  non-trivial files. TDD observed: RED 5/22 → GREEN 22/22 (one test assumption
  corrected on the way: bash repopulates `$SHELL` when unset, so the
  unknown-shell case uses an explicit `/usr/bin/fish`). Checks:
  `bash tests/test_doctor_hook.sh` 22/22; `test_install_port.sh` 10/10;
  `test_hook.sh` 24/24; `test_router.sh` 42/42;
  `test_install_shim_retirement.sh` 25/25; `bash -n bin/engram-doctor` ok; no
  `check_path_precedence`/`precedencia` left. Parent spot check re-ran the new
  test and `test_install_port.sh`: identical; read both new checks and the
  `main()` wiring. RDD assess from the boundary: high. Native preflight via the
  canonical STATUS with `--agent claude-code`, scoped to this commit
  (`--base-ref 2cf16d8`): consent granted; lineage review-b96df8147ed044e9;
  all four lenses admitted. Final capture closed `correction_required` with
  two candidate-caused CRITICAL findings (R2-subshell-global-contract,
  R4-subshell-drops-router-globals): `check_current_repo_routing` called the
  routing helper inside `$(...)`, so the ROUTER_* globals died in the subshell
  and the routing report only looked right because `check_hook_active` had
  populated them earlier — an ordering coupling no test guarded. Real defect
  missed by the writer, the parent readback and the suite. Correction plan
  captured (60 lines); bounded correction delegated and committed as
  `68896df` (13+11 doctor, 36+0 test; the isolated-section test is RED without
  the fix, GREEN with it; full suite green). Targeted validation
  (`review.capture-validation`) then refused twice at preflight with
  `repository_context_unavailable` on the rctx2 handle the lineage STATUS
  itself reissues — equivalent open defect gentle-ai#4664. User chose
  report-and-continue: one occurrence comment posted on #4664, no labels
  touched. The captured candidate-scoped decline could not run:
  `stale_target_identity` (the correction commit changed the candidate tree
  after the consent envelope was issued); per contract no substitute
  invocation was synthesised. Lineage left open at
  `targeted_validation_required`; it gates nothing. Verification of record
  for T3 + correction follows the RDD-off tier (high): writer
  self-verification above plus an independent verifier of 68896df.
  Independent verifier (sonnet, read-only, clean worktree of 68896df):
  reproduced the defect against 0e34ac3's doctor (reset globals → "sin
  instancia resuelta") and its absence at 68896df; full suite 24/24, 10/10,
  24/24, 42/42, 25/25, 19/19, 29/29, `bash -n` ok; all five hook branches,
  `set -u` safety, spaces in data dirs, symlink invocation and exit status
  confirmed; verdict pass. Two low pre-existing notes recorded as follow-ups
  (not this feature): `check_no_shadowing` reports "nada lo ensombrece" when
  the resolved file is unreadable (grep fails silently); trailing-slash
  tolerance strips one slash only. T3 checked off.
- T4 — commit recorded below (this note travels in it). Route: delegated
  writer (sonnet); trigger: 4 files. TDD observed for the one behaviour
  change: RED 27/28 (symlink at `$PREFIX_BIN/engram` not reported) → GREEN
  28/28. Changes: README `## Shell integration` (hook line, resolver, `engram`
  function, MCP-child inheritance, doctor checks, the three limitations, the
  upgrade note; shim row removed from the file table; every "shim must win on
  PATH" sentence replaced); `retire_legacy_shim` now reports and leaves a
  symlink; `_real_home_snapshot` covers the scanned dotfiles; the vacuous
  `type -P` sub-assertion dropped from `test_hook.sh`. Checks: 28/28, 23/23,
  24/24, 10/10, 42/42, 19/19, 29/29; `bash -n` on all scripts ok. Parent spot
  check re-ran the two changed test files: identical; README privacy scan
  clean (only a `/home/you/…` placeholder); read the new section and the
  symlink branch. All four tasks checked off. Commit `0fa5d98`. RDD assess
  (this commit only): high. Native review via canonical STATUS with `--agent`:
  consent granted; lineage review-5b01b5b9baa5e088; four lenses admitted; the
  final capture closed `correction_required` with one candidate-caused
  CRITICAL finding (R4-symlinked-shim-left-active): the symlink branch just
  added told the operator a symlinked shim "no hace falta tocarlo" while a
  link to a marker file is still an active shim shadowing `engram`, and the
  installer could never converge on it — a real defect that the T2 verifier's
  note and my own readback had got wrong. Correction plan captured (50
  lines); bounded correction committed as `fb41f74` (9+3 install.sh, 18+15
  test; RED observed: "symlink to marker file is removed — still present";
  GREEN 31/31; the message assertion was tightened to the actual removal text
  because its first pattern also matched the old message). Targeted
  validation admitted → `approved`; STATUS restart replayed the same
  acknowledgement; exact acknowledgement run once →
  `gentle-ai.review-acknowledged/v1`, `authority: burned`. This is the only
  lineage of the feature that reached a terminal receipt.

## Follow-ups (recorded, not in scope)
- Make `~/.engram` a cloud-less quarantine instance and move the personal
  cloud to a named instance, so desktop-launched agents fail closed too
  (migrates live memories; needs its own decision).
- `check_no_shadowing` should fail, not pass, when the resolved `engram` is
  unreadable (grep fails silently today); trailing-slash tolerance strips one
  slash only.
- Review lineage review-b96df8147ed044e9 (T3) remains open at
  `targeted_validation_required` because of gentle-ai#4664; it gates nothing.

## Next step
Acceptance on the real machine still requires re-running `./install.sh` there
(retires the old shim in `~/.local/bin`, installs the new tools), adding the
hook line to the rc file, opening a new terminal, then: `gentle-ai upgrade`,
`engram-doctor`, and `cd` between a work and a personal repository to watch
`ENGRAM_DATA_DIR` switch. Push / PR remain the user's decision; the branch
holds ~1,900 authored changed lines, above the ~400 slice budget, so the PR
slicing strategy is to be asked once when a PR is requested.
