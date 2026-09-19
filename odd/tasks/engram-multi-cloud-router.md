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

- [ ] P1 Nothing has ever run against a real cloud. install.sh has never been
      executed, no systemd unit has been installed, no second cloud exists.
      This is the gap between a validated design and a working product.
      DONE after this was written: a throwaway `engram cloud serve` proved the
      path, and a real project was later migrated to a real second cloud and
      verified server-side.
- [ ] P2 README does not state that only Linux and macOS are supported, so a
      Windows colleague would clone and discover it by failing.
- [ ] P3 Two upstream defects observed and never reported to
      Gentleman-Programming/engram: `sync_state.target_key` carries no server
      identity (latent silent data loss for anyone repointing an install), and
      enrollment is a destination-blind boolean.
- [ ] P4 Per-machine setup is not part of this document. Each person removes
      their own ENGRAM_CLOUD_* exports and verifies their own credentials;
      `engram-doctor` reports both. Check that the token in an instance's
      cloud.json works BEFORE removing the exports that currently override it.

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
