# Engram multi-cloud router

Routes each git repository's Engram memories to the correct Engram Cloud
(company vs. personal), so switching between work and personal projects
cannot replicate data to the wrong server.

## Why this exists

Engram 2.0.0 has no per-project cloud routing: one process, one global
`cloud.json`, one destination. If your shell also has `ENGRAM_CLOUD_*`
exported (a common personal-account setup), it silently overrides
`cloud.json` for every project, work included. This router closes that gap
without touching Engram itself: it runs multiple isolated Engram instances
(one data dir per cloud) and picks the right one per repository, based on
the repository's git remote.

See `odd/tasks/engram-multi-cloud-router.md` for the full list of verified
findings this design is built on.

## How it works

- **`lib/router.sh`** — shared logic: normalizes a git remote URL to a
  comparable `host[:port]/owner` form, and matches it against your rules
  file (first match wins, evaluated in file order).
- **`bin/engram`** — a shim you put ahead of the real `engram` binary on
  your `PATH`. For every invocation it resolves the current repository's
  instance and sets `ENGRAM_DATA_DIR` accordingly, then execs the real
  binary. It never reads, writes, passes, or logs a token — it only ever
  selects a data directory. Credentials always come from each instance's
  own `cloud.json`.
- **`bin/engram-router`** (also installed as **`engram-where`**) — explains
  routing for a repository: which remote, which rule matched, which
  instance, which cloud server, what state.
- **`bin/engram-doctor`** — read-only diagnostics: environment pollution,
  `PATH` precedence, per-instance credential-source readback, daemon
  liveness, and the routing explanation for your current directory. Exits
  non-zero on any failure.
- **`systemd/engram@.service`** — a templated systemd `--user` unit
  (`engram@work.service`, `engram@personal.service`, ...), one process per
  instance, each with its own `ENGRAM_DATA_DIR` and therefore its own
  database and credentials.

## Resolution order

1. `.engram/config.json` in the repository, if it has an `"instance"` key
   (added alongside the existing `"project_name"` key — no new marker
   file).
2. The first matching rule in `router.json`, evaluated in file order.
3. Unmatched.

## What happens when a repo doesn't match anything

Local Engram operations (`search`, `save`, ...) still work normally,
against whatever the default instance is. **Cloud operations** (`sync`,
`cloud enroll`, `cloud config`, ...) are **refused**, with an explanation of
why and how to add a rule. This asymmetry is deliberate: the shim's failure
mode is silence, never misdirection. It will never guess a destination for
you.

## Install

```sh
./install.sh
```

The installer is interactive, safe to re-run, and:

- Stops immediately (without editing anything) if it finds `ENGRAM_CLOUD_*`
  exported in your shell or in `~/.bashrc`, `~/.profile`,
  `~/.zshrc`/`~/.zprofile`, or `~/.config/environment.d/*.conf`. Those
  variables silently override `cloud.json`; you must remove them by hand.
- Defaults to **one instance (work)**. A personal instance is opt-in.
- Writes each instance's `cloud.json` with `0600` permissions and never
  echoes or logs the token you paste in.
- Verifies afterwards that `engram` on your `PATH` actually resolves to the
  installed shim, and tells you exactly how to fix your `PATH` if not.
- Finishes by running `engram-doctor` and showing you the result.

Colleagues coming from an existing single-instance Engram setup: the
installer will warn you that any projects already enrolled there, and any
sync mutations already queued, are "destination-blind" (they carry no
server identity) — review them before turning on multi-instance sync.

## Configuring your own rules

Edit `~/.config/engram-router/router.json` (installed from
`config/router.example.json` on first run, never overwritten afterwards).
Each rule is:

```json
{ "prefix": "github.com/your-org", "instance": "work" }
```

`prefix` is matched against the normalized remote (`host[:port]/owner`) —
exact match, or as a `/`-bounded prefix. Rules are evaluated top to bottom;
the first match wins. A bare host like `gitlab.com` is **not** assumed to
mean anything by itself — write the full `host/owner` you actually want,
since the same host can host both work and personal repositories.

## Per-repository override

To pin one repository to a specific instance regardless of rules, add to
its `.engram/config.json`:

```json
{ "project_name": "...", "instance": "personal" }
```

## Diagnosing problems

```sh
engram-doctor      # full read-only diagnostic, non-zero exit on failure
engram-where        # routing explanation for the current repository
```

`engram-doctor` never mutates anything — no file, no daemon, no database.

## Uninstalling

Remove `~/.local/bin/engram`, `~/.local/bin/engram-router`,
`~/.local/bin/engram-where`, `~/.local/bin/engram-doctor`,
`~/.local/lib/engram-router/`, `~/.config/engram-router/`, and
`~/.config/systemd/user/engram@.service` (after `systemctl --user disable
--now engram@<instance>.service` for any enabled instance). Your
per-instance data (`~/.local/share/engram-<instance>/`) is left in place;
remove it manually if you no longer need it.
