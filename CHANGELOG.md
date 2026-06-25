## [Unreleased]

### Added
- **Worktrees for existing branches**: Allow creation of worktrees from branches that already exist.
- **Paste support**: Support pasting into new branch and filtering dialogs.
- **Teardown via `.wotr/config`**: Teardown is now declared under the `hooks:` block alongside `new`/`switch`, supporting `bg`/`fg` steps and YAML-embedded scripts.

### Changed
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
