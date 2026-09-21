# Engram Multi-Cloud Router

## Objective
Ship a configure-and-run installer that routes each git repository's Engram
memories to the correct Engram Cloud (company vs personal), so switching
between work and personal projects cannot replicate data to the wrong server.

## Problem
Engram 2.0.0 has no per-project cloud routing. A single global `cloud.json`
plus a resident autosync daemon means every enrolled project replicates to
whichever server the daemon was started with.

## Verified findings (all measured on 2026-09-19, engram v2.0.0)
1. `engram cloud config` accepts only `--server <url> | --clear`. One global
   destination. `engram sync --cloud --project X` has no `--server`/`--token`.
2. Enrollment is destination-blind: `sync_enrolled_projects(project TEXT
   PRIMARY KEY, enrolled_at TEXT)`. No server column. 35 projects already
   enrolled locally; `sync_state` shows a backlog of ~100 unenrolled projects
   held back only by that gate.
3. Autosync is live and runs inside `engram serve`, whose environment is
   frozen at exec. Per-invocation env injection never reaches it.
4. `sync_state.target_key` is `cloud:<project>` with no server identity.
   Repointing one install at a second server reuses `last_acked_seq` across
   different backends. Latent data-loss risk; worth an upstream report.
5. `ENGRAM_DATA_DIR` fully isolates an instance. VERIFIED: a second daemon on
   port 7439 with its own data dir created its own `engram.db` and
   `.instance-id`; a write landed there (0 -> 1) while the main database stayed
   at its full row count and never saw the probe.
6. Credentials resolve from the instance's own `cloud.json` ONLY when the
   environment is clean. VERIFIED side by side, same data dir, same file:
     clean env     -> Server source: cloud.json,            token read from cloud.json
     current env   -> Server source: ENGRAM_CLOUD_SERVER,   personal token
   The user's `ENGRAM_CLOUD_*` exports would silently override a work
   instance's credentials, making it a second personal instance.
7. Those exports are typically duplicated across a shell rc file, a login
   profile, and `~/.config/environment.d/*.conf`. The last one is systemd user
   environment, inherited by every process in the session rather than only by
   shells, so removing the first two is not enough. Duplicated copies drift:
   the ones found during this work already disagreed on a trailing slash.
   Shell rc files are commonly mode 644, which leaves the token world-readable.
8. Autosync is opt-in per instance: with `ENGRAM_CLOUD_AUTOSYNC` unset, the
   probe daemon logged no `[autosync] started` line.
9. Repo-level config already exists: `.engram/config.json` with
   `json:"project_name"`. Use it; do not invent a new marker file.
10. An audit of ~65 real repositories showed work and personal separate by
    namespace with no overlap, which is what makes deriving the instance from
    the remote viable. Parsing gotchas present in that real data, all now
    covered by tests: SCP syntax with a non-standard port (`host:PORT/owner`),
    a `git::@github.com/...` prefix from a plugin manager, and the same host
    appearing on both sides — a self-hosted GitLab for work while gitlab.com
    held personal repositories, so a host alone never implies a role.
    About 40 matched neither: third-party clones, and 11 with no remote at
    all. Those are why unmatched must refuse cloud operations instead of
    falling back to a default.
11. Server-side management already exists: `/dashboard/admin/users`,
    `/dashboard/admin/projects/{name}/sync`, `POST /dashboard/admin/tokens/...`,
    `/dashboard/admin/audit-log`, `/dashboard/admin/health`. Per-principal
    grants are deny-by-default. Nothing to build there.

## Scope
IN: router rules file, PATH shim, per-instance data dirs and systemd user
units, installer, read-only doctor, README for colleagues.
OUT: any change to Engram source; any edit to the user's existing dotfiles,
daemon, or database; server-side dashboard work.

## Constraints
- The common colleague case is ONE instance (work) plus refuse-everything-else.
  Two instances is the advanced case, offered as an option, never imposed.
- Ship no tokens. Each person supplies their own; written to `cloud.json` 0600.
- Never edit a user's dotfiles. Detect the hazardous exports, stop, explain.
- Never assume PATH order. Verify the shim actually wins.
- Shim failure mode must be silence, not misdirection: pass local operations
  through, refuse cloud operations when routing is unresolved.
- Artifacts in English; user-facing installer output in Spanish.

## Delivery
Published as a public repository created during this work, under a personal
namespace rather than the organization the tool serves; transferable later with
`gh repo transfer`.

Supported platforms: Linux and macOS. Windows was evaluated and declined.

TDD mode: unresolved for this workspace, so no RED-before-GREEN evidence is
claimed. Verification is by unit tests on remote parsing, shellcheck, and
fixture-HOME smoke tests of the installer and uninstaller paths. RDD is off,
so no native review ran and none is claimed.

## Tasks

Route for every task below: delegated direct (one bounded writer for T1-T6,
writer trigger fired at 2+ non-trivial files), then direct inline for the
corrections, each a single already-understood file.

- [x] T1 Router core — remote parsing, rule matching, fail-closed resolution.
      Evidence: 35/35 bash tests, shellcheck clean. Commit c433f32.
- [x] T2 Shim — local ops pass through, cloud ops refused when unresolved,
      never touches a token, resolves the real binary without recursion.
      Evidence: covered by the same suite. Commit c433f32.
- [x] T3 Instance provisioning — data dir 0700, cloud.json 0600, templated
      systemd unit, per-instance autosync. Commit c433f32, corrected in 3d9c156.
- [x] T4 Installer — preflight, hazard detection, token prompt, PATH check.
      Commit c433f32, extended in eccc25c.
- [x] T5 Doctor — env pollution, PATH precedence, destination readback, daemon
      liveness, routing explanation. Evidence: it live-detected this machine's
      real ENGRAM_CLOUD_* pollution during smoke tests. Commit c433f32.
- [x] T6 README — rewritten around what the tool does to an Engram install.
      Commit 3d9c156.

Emerged after the original breakdown:

- [x] T7 Fix cloud.json key — install.sh wrote "server"; Engram reads
      "server_url". Evidence: measured both against engram v2.0.0 with a clean
      environment — "server" yields `not configured (no effective server URL)`
      while still reading the token, so an instance looked half configured.
      Commit 3d9c156.
- [x] T8 Any number of named instances — only the installer wizard was binary;
      the core never hardcoded names. Evidence: three interactive paths tested,
      including an invalid name rejected mid-loop. Commit eccc25c.
- [x] T9 uninstall.sh — never removes memories without --purge-data, confirms
      each instance separately, discovers instances from config or from data
      dirs. Evidence: fixture HOME covering preservation, selective purge,
      discovery with the config already deleted, a second run on a clean HOME,
      and ~/.engram untouched throughout. Commit a52ccfa.
- [x] T10 Windows support — evaluated and DECLINED by the user. Engram ships
      native Windows binaries, so the engine was not the obstacle; ours were
      PATHEXT shim resolution and chmod being a silent no-op. Recorded
      recommendation if reopened: a Go core, with these tests as its spec.

## Pending

- [x] P1 Run against a real cloud. A throwaway `engram cloud serve` proved the
      path end to end, and a real project was then migrated to a real second
      cloud: 147 observations exported, imported, counted, enrolled and pushed,
      with the server returning them on a pull afterwards.
- [x] P2 README states the supported platforms, and records the Windows
      decision with its reasoning so it does not get re-derived.
- [~] P3 DECLINED by the user: the two upstream defects will not be reported.
      Recorded so the analysis is not redone. `sync_state.target_key` carries
      no server identity, so acknowledgement cursors are reused across
      different backends — latent silent data loss for anyone repointing an
      install at a second server, not only a multi-cloud user. And enrollment
      is a destination-blind boolean. The design here avoids both by never
      repointing an instance: one instance per destination, always.
- [x] P4 Per-machine setup moved out of this document and into `engram-doctor`,
      which reports environment pollution and each instance's real destination
      for whoever runs it.

Emerged while using it:

- [x] P5 Six projects now live in `trabajo`: mcp-mysql, mcp-hana,
      esp32-ble-wearos, copobrasil.com, mqtt_wear_pack, vioncasbake206.
      The last five were found by cross-checking every enrolled project's
      `git remote` against the routing rules rather than against its name —
      `copobrasil.com` and `vioncasbake206` read as personal and are not.
      All five had been replicating to the personal cloud since August.
      Counts matched on every migration (25·25, 11·11, 24·24, 2·2, 6·6) and
      each reached the work cloud at 1/1 chunks, pending 0. Seven projects
      remain in `personal` and every one of them is genuinely personal.
- [x] P6 Both instances now autosync, each on its own port and each to its
      own server, with both units enabled so they survive a reboot. Neither daemon carries ENGRAM_CLOUD_SERVER or ENGRAM_CLOUD_TOKEN;
      each reads its own cloud.json, which is the whole mechanism working.
      Enabling the second one is what exposed T12 below.
- [x] P7 Parsing text meant for humans is unavoidable — `engram doctor --json`
      exists but `cloud status` has no equivalent — so it now fails honestly:
      a missing label is reported as a possible format change rather than as a
      configuration problem, and `engram-doctor` warns on version drift.
- [ ] P8 With more than one contributor, commits should stop going straight to
      `main`: a branch and a pull request per change, especially for a tool
      whose failures are silent.

Operational, per person rather than per project:

- Rotate any token that has been exposed. Tokens reach crash dumps, terminal
  transcripts and world-readable rc files; `engram-doctor` catches only the
  file modes.

Emerged on 2026-09-21, while making the tool actually run on a real machine.
Every one of these predates that day's work; none was introduced by it.

- [x] T12 The systemd template never passed a port, so every instance bound
      7437 and two could never coexist — the project's central use case. The
      second instance printed `[autosync] started` and died one line later,
      which is a trap: the reassuring line comes first. `router.example.json`
      documented `port` per instance and `lib/router.sh` parsed it into
      INSTANCE_PORT, but `install.sh` never wrote it and the unit never read
      it. install.sh now assigns the first free port from 7437, stable across
      re-runs; the unit passes `serve $ENGRAM_PORT`, which systemd drops
      entirely when unset, so old installs fall back to 7437 unchanged.
      Commit f6c6ff2. Evidence: 42/42 router, 10/10 new suite, 19/19 contract,
      shellcheck clean.
- [x] T13 `engram-migrate` migrated the source's local database, never the
      source's cloud, so anything living only on the old server stayed
      stranded while the summary still printed "Hecho". It now pulls the
      source cloud first and refuses to continue when that pull fails; a
      source with no cloud.json is the one case that proceeds, with a reason.
      Commit d9e3921. Evidence: 29/29 new suite, and the fail-closed path
      verified to work because the script sets `pipefail` — without it the
      `|| die` after a pipe would never fire.

- [ ] T14 `engram-where` prints `estado: enrolled` whenever the instance has a
      readable cloud.json. It never queries `sync_enrolled_projects`, so it
      reported `enrolled` for a project enrolled in neither instance. The one
      line meant to tell you whether a repo will replicate does not measure
      that.
- [ ] T15 The systemd template derives ENGRAM_DATA_DIR from the instance name
      instead of reading router.json's `data_dir`. An instance that adopted an
      existing Engram root gets an empty directory and serves nothing, with no
      warning. Worked around on this machine with a per-instance EnvironmentFile
      entry; unfixed in the repository.
- [ ] T16 `engram-migrate` parses router.json with its own `sed`, which cannot
      cross newlines, so any valid reformatting breaks it — and it then blames
      the user's configuration ("la instancia no está en router.json") instead
      of admitting it could not parse. `lib/router.sh` already has the parser
      it should be using.

## Progress notes

Delivery: not planned as chained PRs; commits went straight to `main` while
one person worked on it. With more than one contributor that should change to
a branch and a pull request per change.

Sanitization: real identifiers appeared in five files, not one. Placeholdered
before the first commit, because a published commit stays in history. This
document is published sanitized for the same reason: the design rationale is
worth sharing, the state of any one machine is not.

Process gap, recorded honestly: T1-T10 outcomes were each verified when they
happened, but this file was not updated as they landed and no Engram mirror
existed until now. The evidence above was reconstructed from commits and test
runs, not written at the time.
