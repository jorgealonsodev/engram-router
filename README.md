# engram-router

Route each git repository's [Engram](https://github.com/Gentleman-Programming/engram)
memories to the correct Engram Cloud, so moving between work and personal
projects cannot replicate data to the wrong server.

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
| `~/.local/bin/engram-where` | symlink to `engram-router` | — |
| `~/.local/lib/engram-router/router.sh` | shared library | 0644 |
| `~/.config/engram-router/router.json` | your routing rules | 0644 |
| `~/.config/engram-router/instances/<name>.env` | per-instance autosync flag | 0644 |
| `~/.config/systemd/user/engram@.service` | templated user unit | 0644 |
| `~/.local/share/engram-<instance>/` | instance root | 0700 |
| `~/.local/share/engram-<instance>/cloud.json` | that instance's credentials | **0600** |

`~/.local/share/engram-<instance>/engram.db` and `.instance-id` are created by
Engram itself the first time that instance's daemon starts. This tool never
writes them.

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

The installer is interactive and idempotent. It asks for instance names one at
a time — press Enter on the first prompt to accept a single `work` instance, or
name as many as you need. For each one it prompts for the server URL and token,
writes them to that instance's `cloud.json` with mode 0600, and never echoes or
logs the token. It then verifies the shim actually wins in `PATH` and runs the
doctor.

Get your token from your cloud's dashboard (`/dashboard/admin/users`). Tokens
are per person; this repository ships none.

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

## Diagnosing

```sh
engram-where     # where does THIS repository sync, and why
engram-doctor    # environment, PATH, destinations, daemons; non-zero on failure
```

## Uninstalling

```sh
systemctl --user disable --now engram@<instance>.service
rm -rf ~/.local/bin/engram ~/.local/bin/engram-{router,doctor,where} \
       ~/.local/lib/engram-router ~/.config/engram-router \
       ~/.config/systemd/user/engram@.service
```

Instance data under `~/.local/share/engram-*` is left in place; remove it
deliberately, since it holds memories that may not exist anywhere else.
