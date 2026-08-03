## [Unreleased]

### Added
- **Resource leases (holder visibility, expiry, non-silent takeover)**: Exclusive resources now carry a *lease* — a shared record of which worktree holds them, when it was acquired, and when ownership was last confirmed. Taking a resource is no longer silent in either direction.
  - `wotr acquire <resource>` checks who holds the resource first (via its `inquire` probe, so a stale lease can never mask a live server). If another worktree holds it, wotr waits a bounded interval (default 15s) and then **fails with an actionable decision** instead of silently stealing: `--force` to take it anyway, `--wait` to keep waiting. On success it records the lease.
  - `wotr resources` now shows **who holds each resource** — holder worktree, how long ago it was acquired, and when it was last renewed (with a `[lapsed]` marker when the lease has expired).
  - `wotr release <resource>` gives up this worktree's lease.
  - Leases **expire**: an abandoned worktree's claim lapses on its own after its TTL (default 30 min, per-resource `lease_ttl_minutes:`), so the common case self-heals with no cleanup command.
  - Deleting a worktree via wotr **releases every lease it held**.
  - The lease store lives in the shared wotr state dir (`.worktrees/<repo>/.wotr/leases.json`), outside any single worktree, and is flock-guarded for concurrent access.
- **`wotr new <branch>` CLI command**: Create a worktree (branched from `origin/<default-branch>`) from the command line, without driving the TUI. Create-only by default (setup is deferred until entry, mirroring the TUI), so it's safe to script. Pass `--switch` to enter the new worktree: run the `new` (setup) and `switch` hooks and drop into a shell in it. Idempotent — acts on an existing worktree instead of failing. Enables automation such as spawning a worktree in a fresh terminal/workspace.
- **Worktrees for existing branches**: Allow creation of worktrees from branches that already exist.
- **Paste support**: Support pasting into new branch and filtering dialogs.
- **Teardown via `.wotr/config`**: Teardown is now declared under the `hooks:` block alongside `new`/`switch`, supporting `bg`/`fg` steps and YAML-embedded scripts.

### Changed
- **Behavior change — `wotr acquire` on a held exclusive resource no longer steals silently.** Previously `wotr acquire <resource>` always ran the acquire script and returned success, seizing the resource from whatever worktree held it. It now checks the holder first and, if another worktree holds it, **waits a bounded interval (default 15s) then exits non-zero** with a decision (`--force` to take it anyway, `--wait` to keep waiting). Automation that relied on `wotr acquire` unconditionally succeeding must pass `--force` (or set `WOTR_ACQUIRE_WAIT`). Applies to exclusive resources only; compatible resources are unaffected.
- **BREAKING**: Removed legacy `.wotr/teardown` executable script in favour of `hooks.teardown` in `.wotr/config`. Repos that defined a `.wotr/teardown` file must move its body into the config under `hooks: teardown: - bg: |`.

## [0.1.4] - 2026-01-30

### Added
- **Permanent CD on exit**: After quitting wotr, your shell stays in the last resumed worktree directory
- **Visible setup output**: `.wotr/setup` script now runs with visible output on first resume (not during worktree creation)
- **Teardown support**: Optional `.wotr/teardown` script runs before worktree deletion
- **WOTR_ROOT environment variable**: Setup and teardown scripts receive `$WOTR_ROOT` pointing to the repo root
- Integration tests for setup/teardown functionality
- Homebrew update instructions in deploy script

### Changed
- Setup now runs on first resume instead of during worktree creation
- Setup only runs once per worktree (tracked via `.wotr_needs_setup` marker)

## [0.1.0] - 2026-01-29

- Initial release
