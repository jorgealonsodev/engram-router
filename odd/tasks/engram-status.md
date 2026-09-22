# engram-status

## Objective
One command that answers "is my memory actually syncing, and to which cloud?"
without opening SQLite by hand — which is what diagnosing it took all of
2026-09-22.

## Problem
`engram-doctor` checks health and configuration: versions, shadowing, the
hook, ports, daemons, credentials. It does not show sync state. The only way
to see whether an instance is pushing, how far behind it is, or why it is
degraded, is to query `sync_state` in each instance's `engram.db` directly.
The journal is no help: the daemons log `[autosync] started` and nothing per
cycle.

## Scope
IN: a new `bin/engram-status` alongside the existing namespaced tools
(`engram-router`, `engram-doctor`, `engram-migrate`, `engram-where`),
installed by `install.sh` and removed by `uninstall.sh`; a `--json` mode.
OUT: any write. This tool never changes anything — no enroll, no sync, no
config edit. It is read-only by construction.

## What it shows, per instance
- name, data dir, port, and whether its systemd unit is active
- the cloud it points at (`server_url` from that instance's `cloud.json`) and
  where that came from, plus whether a token is present — never its value
- autosync on or off (from the instance's env file)
- sync lifecycle from `sync_state` where `target_key='cloud'`: healthy or
  degraded, how many mutations are enqueued vs acknowledged, last pulled,
  `reason_code` and `last_error` when present, and the last success time
- enrolled projects, and projects holding unsynced mutations that are NOT
  enrolled (the reason an instance reads `degraded`)

## And once, for the current directory
Which instance this repository resolves to, or that it resolves to none.

## Constraints
- Read-only. Opens every database with `mode=ro`.
- Never prints a token, and never prints a cloud URL in `--json` unless the
  same URL is already printed in the human output.
- Degrades instead of failing: a missing `cloud.json`, an unreadable
  database, a stopped daemon or an absent `sync_state` row each render as a
  stated unknown, not an error, and never abort the other instances.
- Exit status: 0 when every instance is healthy, non-zero when any is
  degraded or unreadable, so it can be used in a script.
- Follows the repo's conventions: bash, `set -euo pipefail`, Spanish user
  output, English code and tests, plain-bash tests with PASS/FAIL counters,
  fixture `$HOME`, real-`$HOME` snapshot.
- The installer must not grow a question.

## Acceptance
1. Run in a repository, prints both instances with their cloud, daemon state,
   autosync, lifecycle and counters, and names the instance this repo routes
   to.
2. `--json` emits the same facts as parseable output, no tokens.
3. An instance with a stopped daemon, no `cloud.json`, or an unreadable
   database is reported as such while the others still render.
4. Installed by `install.sh`, removed by `uninstall.sh`.
5. All tests pass.

## Route and mode
- Route: delegated direct (one writer for `bin/engram-status` plus its suite).
- TDD: strict, per the session configuration. Runner: plain bash,
  `bash tests/test_status.sh`, PASS/FAIL counters like the rest of the suite.
- Delivery strategy: `single-pr` — one branch, `feat/engram-status`, merged to
  `main`. 1115 authored changed lines, of which 457 are the test suite and 59
  this document; `bin/engram-status` itself is 597 new lines and nothing
  existing was rewritten (0 deletions), so the change does not compete for
  review attention the way the 400-line budget is meant to protect.

## Tasks
- [x] T1 — `bin/engram-status` reads every instance and renders the human view.
      Commit c480f09.
- [x] T2 — `--json` mode with the same facts, no token values. Commit c480f09.
- [x] T3 — Degrade instead of failing on a missing `cloud.json`, an unreadable
      database, a stopped daemon or an absent `sync_state` row. Commit c480f09.
- [x] T4 — Installed by `install.sh`, removed by `uninstall.sh`. Commit c480f09.
- [x] T5 — A failed query is never reported as an empty result. Commit 637e8cc.
- [x] T6 — This document. Commit 2b92c9b.

## Verification evidence
Measured on 2026-09-22, on the real machine, with both instances running.

- `bash tests/test_status.sh` — 41 passed, 0 failed.
- Whole suite, 11 files — 350 passed, 0 failed.
- `shellcheck bin/engram-status` — two SC2034 warnings on `RULE_PREFIXES` and
  `RULE_INSTANCES`, the arrays `lib/router.sh` fills. `bin/engram-doctor`
  carries the identical pattern at lines 422-424; this is the repository's
  existing convention for resetting them, not a defect introduced here.
- Acceptance 1: run in this repository, it printed both instances with cloud,
  daemon state, autosync, lifecycle and counters, and named `personal` as the
  instance this repository routes to.
- Acceptance 2: `--json` parsed as valid JSON; the only occurrence of the word
  token is `"token_present": true`, a boolean. No value is printed.
- Acceptance 3: one instance rendered as degraded, with its `reason_code` and
  the projects holding unsynced mutations, while the other still rendered
  healthy — the two instances do not take each other down.
- Acceptance 4: `install.sh:173` installs it 0755, `uninstall.sh:99` removes it.
- Native review: `gentle-ai review assess --base-ref main --committed-only`
  reports `risk: high` (executable mode, shell process boundary) and
  `review_due: false`, `review_due_reason: already_reviewed`, candidate
  `consumed: true` — the range carries terminal review authority already.

## What this tool has already earned
Enabling autosync on an instance enrols every project it is still holding —
it does not merely start pushing what was already enrolled. That turns a
one-line configuration change into a bulk upload, and nothing in the existing
tooling showed it: the daemons log `[autosync] started` and then go quiet.
`engram-status` makes the enrolled-project count a number you read off the
screen, so a jump in it is visible the moment it happens rather than weeks
later. It caught exactly that on the day it was installed.

## Next step
Closed. Merged to `main`. The remaining router backlog (T14, T15, T16, P8)
lives in `engram-multi-cloud-router.md`.
