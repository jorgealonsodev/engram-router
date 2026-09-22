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
