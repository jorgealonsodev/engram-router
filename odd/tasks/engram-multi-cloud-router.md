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

RDD: ON as of 2026-09-21 (decided by global), so native review now runs on
work-unit commits. The note below about RDD being off describes 2026-09-19.

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

- [x] T11 Preflight: avisar antes de destruir la única copia del token.
      El preflight se paraba correctamente ante ENGRAM_CLOUD_*, pero sus
      propias instrucciones ("elimine esas líneas") destruían la única copia
      del token sin comprobarlo nunca. Medido: ~/.engram/cloud.json con token
      vacío, y el valor vivo solo en .bashrc:148 y .profile:32. Alcance
      elegido: SOLO AVISAR, sin escribir credenciales a disco. Commits
      8276aa0, 45399bd. Revisión nativa: dos hallazgos CRITICAL, corregidos
      en 981d05a — la comprobación de supervivencia era por presencia y no
      por identidad (fail-open: un token distinto hacía decir "puede
      continuar con seguridad"), y el README afirmaba que ~/.engram/cloud.json
      no se lee cuando el mismo cambio lo lee.
      Evidencia: 35/35 router, 19/19 contrato contra Engram 2.0.0 real,
      32/32 test nuevo con HOME de fixture y checksum del $HOME real,
      shellcheck limpio, y ./install.sh sobre el caso real de la máquina.
      Revisión: lineage review-693ed30b7dbc1a9a, aprobada y acuse quemado.

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

- [ ] P5 Only one project has been migrated. The rest still live in whichever
      instance predates the split, and `engram-migrate` handles them one
      repository at a time.
- [ ] P6 Per-instance systemd units are installed but not enabled, so nothing
      replicates on its own. Decide whether autosync should be on per instance,
      remembering it is opt-in and that a resident daemon freezes its
      environment at exec.
- [x] P7 Parsing text meant for humans is unavoidable — `engram doctor --json`
      exists but `cloud status` has no equivalent — so it now fails honestly:
      a missing label is reported as a possible format change rather than as a
      configuration problem, and `engram-doctor` warns on version drift.
- [x] P9 The default data-directory answer started an instance on an empty
      database while an existing install's memories stayed in ~/.engram,
      unreferenced — nothing failed and nothing warned. The installer now
      probes ~/.engram and $ENGRAM_DATA_DIR before asking, and when it finds
      a root no instance has claimed it reports the root with its size and
      counts and drops its default entirely: an empty answer is refused, so
      nobody lands on an empty database by pressing Enter. A root already
      claimed earlier in the run is not offered again, so a second instance
      is never pushed toward the first one's database. Counts are read with
      `sqlite3 -readonly` and reported as unreadable rather than estimated
      when sqlite3 is missing or the file will not parse.
      Commits e209dce, cd05400. Evidence: 29/29 on the new suite, 35/35
      router, 32/32 token warning, 19/19 contract against real Engram 2.0.0,
      shellcheck clean, and the read-only queries run against the live
      63.5 MB database (3373 observations, 35 projects) with its WAL
      untouched.
      Review lineage review-1cf22636190b081b, approved, acknowledgement
      burned. It caught one CRITICAL from two lenses: the no-default prompt
      spun forever on stdin EOF, because refusing an empty answer and
      re-reading consumes nothing once the stream is finished. Proven
      standalone at five iterations and zero bytes read, fixed in cd05400,
      and the harness now runs under `timeout` so a non-terminating prompt
      fails a check instead of hanging the suite.

- [ ] P8 With more than one contributor, commits should stop going straight to
      `main`: a branch and a pull request per change, especially for a tool
      whose failures are silent.

Advisory findings left open by the P9 review (non-blocking, recorded so they
are not rediscovered). Highest value first:

- [ ] P10 `_root_is_claimed` compares resolved paths as strings, so a root
      reached through a symlink or a differently-spelled path is not
      recognised as claimed and could be offered twice. Same class:
      `_existing_engram_roots` probes only ~/.engram and $ENGRAM_DATA_DIR,
      and `_describe_engram_root` depends on GNU `stat -c` and on bash 4
      associative arrays, which macOS ships neither of by default —
      the README claims macOS support.
- [ ] P11 The answer `nueva` is a bare sentinel: a user whose directory is
      genuinely named `nueva` cannot express it, and no other input is
      normalised the same way.
- [ ] P12 The new test harness reads its result from the last line of
      output, so anything printed afterwards silently changes what is
      asserted.

Operational, per person rather than per project:

- Rotate any token that has been exposed. Tokens reach crash dumps, terminal
  transcripts and world-readable rc files; `engram-doctor` catches only the
  file modes.

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
