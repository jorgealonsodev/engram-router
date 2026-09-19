# engram-router

Route each git repository's [Engram](https://github.com/Gentleman-Programming/engram)
memories to the correct Engram Cloud, so moving between work and personal
projects cannot replicate data to the wrong server.

## Requirements

Linux or macOS. The shim, the installer and the per-instance daemons are bash
and systemd user units; Windows is not supported and is not planned — see
[Not supported](#not-supported).

Engram itself, `git`, and `sqlite3` for the migration's row check (optional;
without it the check degrades to a weaker one).

## Why this exists

Engram has no per-project cloud routing.

- `engram cloud config` accepts one global `--server`. There is a single
  `cloud.json` for the whole installation.
- Enrollment (`engram cloud enroll <project>`) decides **whether** a project
  replicates, never **where**. Its table is
  `sync_enrolled_projects(project TEXT PRIMARY KEY, enrolled_at TEXT)` — no
  server column.
- Autosync runs inside the resident `engram serve` daemon, whose environment
  is frozen at exec. Setting `ENGRAM_CLOUD_SERVER` per command never reaches it.
- `sync_state.target_key` is `cloud:<project>`, with no server identity, so
  repointing one installation at a second server reuses acknowledgement
  cursors across different backends.

The consequence: with one installation and two clouds, whichever server the
daemon started with receives everything that is enrolled.

This tool does not patch Engram. It gives each destination its own isolated
Engram instance and picks the right one per repository.

## How it works

```
  git remote origin
        |
        v
  .engram/config.json "instance"  ->  explicit override
        |  (absent)
        v
  rules in router.json            ->  first matching prefix wins
        |  (no match)
        v
  local operations: default instance
  cloud operations: REFUSED
```

Each instance is a separate Engram installation root: its own data directory,
database, sync cursors, enrollment set and credentials. Two instances cannot
contaminate each other because they share no state.

### Fail-closed, asymmetrically

Local operations (`search`, `save`, `context`) always pass through. Cloud
operations (`sync`, `cloud ...`) are refused whenever routing is unresolved.

This asymmetry is deliberate: a routing bug degrades to *no sync*, which is
noisy and recoverable, instead of *wrong sync*, which is silent and permanent.

## Files this tool touches

### Creates — all new, none shared with an existing installation

| Path | Purpose | Mode |
|---|---|---|
| `~/.local/bin/engram` | the PATH shim | 0755 |
| `~/.local/bin/engram-router` | resolution and explanation | 0755 |
| `~/.local/bin/engram-doctor` | read-only diagnostics | 0755 |
| `~/.local/bin/engram-migrate` | moves a project between instances | 0755 |
| `~/.local/bin/engram-where` | symlink to `engram-router` | — |
| `~/.local/lib/engram-router/router.sh` | shared library | 0644 |
| `~/.config/engram-router/router.json` | your routing rules | 0644 |
| `~/.config/engram-router/instances/<name>.env` | per-instance autosync flag | 0644 |
| `~/.config/systemd/user/engram@.service` | templated user unit | 0644 |
| `~/.local/share/engram-<instance>/` | instance root | 0700 |
| `~/.local/share/engram-<instance>/cloud.json` | that instance's credentials | **0600** |

`~/.local/share/engram-<instance>/engram.db` and `.instance-id` are created by
Engram itself, the first time anything reaches that instance — through its
daemon or through the shim. This tool never writes them.

### Reads, never modifies

| Path | Why |
|---|---|
| `<repo>/.engram/config.json` | the optional `instance` key, read alongside Engram's own `project_name` |
| `<repo>/.git/config` | the `origin` remote, via `git remote get-url` |

`.engram/config.json` is Engram's existing per-repository config file. This
tool adds an `instance` key to it rather than introducing a second marker file.

### Never touched

- **`~/.engram/`** — an existing single-instance installation, its database,
  its `cloud.json` and its enrollments are left exactly as they are. Nothing in
  this repository references that path.
- **Your dotfiles.** `install.sh` scans `~/.bashrc`, `~/.profile`,
  `~/.zshrc`, `~/.zshenv` and `~/.config/environment.d/*.conf` for
  `ENGRAM_CLOUD_*` exports and **stops with instructions** if it finds any. It
  never edits them.
- **Engram's source.** No patch, no fork, no rebuild.

## The environment hazard

Engram resolves credentials from `cloud.json` **only when the environment is
clean**. Environment variables win:

```
clean environment      Server source: cloud.json
ENGRAM_CLOUD_* set     Server source: ENGRAM_CLOUD_SERVER
```

If `ENGRAM_CLOUD_SERVER` and `ENGRAM_CLOUD_TOKEN` are exported globally, every
instance silently uses those instead of its own `cloud.json` — a "work"
instance would present the personal token to the company server. Remove those
exports before installing. `engram-doctor` checks for them.

Note that `~/.config/environment.d/*.conf` is systemd *user* environment,
inherited by every process in the session, not only by shells.

## Install

```sh
git clone https://github.com/your-user/engram-router
cd engram-router
./install.sh
```

The installer is interactive and idempotent. For each instance it asks, in
order, for a name, the directory that will hold its database, the namespaces
whose repositories should use it, and then its server URL and token. Every
prompt states the accepted format and how to skip it. It finishes by verifying
that the shim wins in `PATH`, reading the configuration it just wrote back with
the router's own parser, and running the doctor.

Get your token from your cloud's dashboard (`/dashboard/admin/users`). Tokens
are per person; this repository ships none. Credentials go into that instance's
`cloud.json` with mode 0600, and are never echoed or logged.

### What it refuses

Input that could only fail later is rejected at the prompt, and it asks again:

| Answer | Why it is refused |
|---|---|
| `https://github.com/org` as a namespace | the scheme is not part of a normalized remote; it suggests `github.com/org` |
| `github.com/org/repo.git` | same, without the `.git`; a prefix with it can never match |
| `github.com/org/repo/extra` | a namespace stops at the owner |
| `http://…` as a server URL | Engram refuses to send a bearer token unencrypted, so it could never sync |
| a data directory that exists as a file, or whose parent is not writable | caught here rather than several steps later, after the token has been typed |

### Re-running it

Over an existing configuration it shows what is there and offers to keep it,
add an instance, modify one, or start over. Modifying one lists its current
namespaces and adds to them: type a new one to append it, or `-<namespace>` to
drop it. Nothing has to be retyped, instances you are not touching are never
re-asked for credentials, and the previous `router.json` is backed up beside
itself.

If the configuration it writes cannot be parsed back, the backup is restored
and the install stops rather than leaving a file the router cannot read.

## How many instances

Instance names are free-form. Nothing in the core hardcodes `work` or
`personal`: a name is a map key, an `engram-<name>` directory suffix, and `%i`
in the templated systemd unit.

**Create one instance per cloud you replicate to — never one per context.**

Instances are isolation boundaries, not folders. They share no database, so a
search inside one cannot see the memories of another. That isolation is the
whole point when the destinations differ, and pure loss when they do not. Three
clients that all sync to the same company cloud belong in one instance,
separated by Engram's own project names; three clients with three separate
Engram Clouds genuinely need three instances.

Each instance costs a port, a user unit and a resident daemon.

## Configuring your rules

`~/.config/engram-router/router.json`, modelled on `config/router.example.json`:

```json
{
  "rules": [
    { "prefix": "github.com/your-org",              "instance": "work" },
    { "prefix": "gitlab.example.com:8443/your-user", "instance": "work" },
    { "prefix": "github.com/your-user",              "instance": "personal" }
  ]
}
```

Rules match a normalized `host[:port]/owner` form, first match wins, in file
order. Never assume a host implies a role — a self-hosted GitLab can be the
work one while `gitlab.com` hosts personal repositories.

These remote forms are all normalized and covered by tests:

```
git@github.com:org/repo.git
https://github.com/org/repo.git
ssh://git@gitlab.example.com:8443/owner/repo.git
gitlab.example.com:8443/owner/repo.git     # SCP syntax with a port
git::@github.com/owner/repo                # plugin-manager prefix
```

## Per-repository override

```json
{
  "project_name": "my-project",
  "instance": "work"
}
```

in that repository's `.engram/config.json`. It beats the rules. Commit it and
your teammates inherit the routing.

## Moving a project between instances

A project whose memories already live in one instance does not move by being
enrolled elsewhere: enrollment grants replication, it does not carry data. The
manual procedure is eight steps and three of them fail quietly when skipped, so
it is scripted:

```sh
cd <repository>
engram-migrate --from personal --to work --dry-run   # show the plan
engram-migrate --from personal --to work             # do it
```

It verifies the destination resolves from its own `cloud.json` before touching
anything, exports (project-scoped), imports, **checks the counts agree before
pushing**, enrolls only once the data is there, pushes, unenrolls the source
last, and deletes the exported chunks.

Every call runs with `ENGRAM_CLOUD_*` stripped and reaches the real binary
directly, so neither a polluted environment nor the shim can redirect a
migration in progress.

If any step fails, nothing after it runs: the source keeps its memories and its
enrollment, and the exported chunks stay on disk. Import is idempotent, so
fixing the problem and re-running resumes rather than duplicating.

The exported chunks are kept and added to the repository's `.gitignore`. They
are not deleted, because the source records every chunk it ever produced and
will not regenerate one: deleting them leaves a re-run reporting "Nothing new
to sync" while the destination stays empty, and the only way back is
`engram sync --all`, which exports every project at once. `--clean-chunks`
removes them anyway, and says that the migration becomes unrepeatable.

**The destination must be HTTPS.** Engram refuses to send a bearer token over
plain HTTP (`bearer token requires an HTTPS remote URL`), so a cloud served on
`http://` cannot be pushed to with a token at all.

Two things it deliberately does not do. It does not delete the source memories
— `--keep-source-enrolled` even leaves them replicating. And it cannot remove
what a previous cloud already received; that is your decision, not a routing
one.

**Run it before adding a routing rule for that repository.** The shim exports
`ENGRAM_DATA_DIR` unconditionally, so once a rule sends the repo to the
destination there is no way to export from the source.

### Never commit exported chunks

`engram sync` prints `git add .engram/ && git commit`. Do not follow it for
`.engram/chunks/`: those are your memories in portable form, and committing
them publishes their contents to everyone with repository access.
`engram-migrate` deletes them for you. `.engram/config.json` is the part meant
to be committed.

## When Engram itself is upgraded

`engram-doctor` reports the installed Engram version and warns when it is not
the one this tool was verified against. It is a warning, never a failure: a
newer Engram is expected to work.

It is worth saying out loud because three checks parse text meant for humans —
`Server source:` and `Observations:` in `engram-router` and `engram-migrate`,
and `No new chunks to import` in `engram-migrate`. A reworded message breaks
those **silently**: `engram-where` would report a missing `cloud.json`, and a
migration would accept an empty import. That class of failure has already
happened once here, over a key name in `cloud.json`.

Everything else is on firmer ground. `ENGRAM_DATA_DIR` is documented in
`engram --help`, and `cloud enroll`, `cloud unenroll`, `cloud status` and
`sync --import` are public subcommands. The shim and the routing depend on
none of it: they set `ENGRAM_DATA_DIR` and exec the real binary.

After upgrading Engram, run `engram-doctor` and check that each instance shows
its server before trusting a migration.

## Diagnosing

```sh
engram-where     # where does THIS repository sync, and why
engram-doctor    # environment, PATH, destinations, daemons; non-zero on failure
engram-migrate   # move a repository's memories between instances
```

## Not supported

**Windows.** Engram itself ships native Windows binaries, so the engine is not
the obstacle — this tool is. A shim cannot be a file without an extension there,
since PATH resolves through `PATHEXT`, and it is unclear whether a `.cmd` would
resolve in a `CreateProcess` call without a shell, which is how an MCP client
spawns it. Worse, `chmod 0600` is a silent no-op on Windows, so the protection
on `cloud.json` would appear to be applied and would not be.

Porting it would mean a second implementation that has to behave identically
forever. If it is ever done, the core belongs in Go rather than PowerShell:
a real `.exe` resolves everywhere, and one codebase can handle both permission
models.

## Uninstalling

```sh
./uninstall.sh                 # remove the tool, keep every memory
./uninstall.sh --purge-data    # also offer to delete each instance's data
```

It shows what it will remove and asks before doing anything (`--yes` skips that
prompt, but never the data prompts).

**Memory data is never removed unless you ask.** Without `--purge-data`, every
`~/.local/share/engram-<instance>/` directory is left untouched and reported.
With it, each instance is confirmed separately, because an instance whose
memories never reached a cloud has no copy anywhere else.

Instances are discovered from `router.json` when present and from the data
directories otherwise, so a partial or hand-edited install still uninstalls
cleanly. Running it twice is safe.

`~/.engram` — an existing single-instance installation — is never read, moved
or removed.

After uninstalling, `engram` is the original binary again, with no routing. If
you removed `ENGRAM_CLOUD_*` from your environment when you installed, check
that the original credentials still work before syncing:

```sh
engram cloud status    # expect: Server source: cloud.json
```
