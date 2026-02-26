## [Unreleased]

### Added
- **Worktrees for existing branches**: Allow creation of worktrees from branches that already exist.
- **Paste support**: Support pasting into new branch and filtering dialogs.

## [0.1.4] - 2026-01-30

### Added
- **Permanent CD on exit**: After quitting cwt, your shell stays in the last resumed worktree directory
- **Visible setup output**: `.cwt/setup` script now runs with visible output on first resume (not during worktree creation)
- **Teardown support**: Optional `.cwt/teardown` script runs before worktree deletion
- **CWT_ROOT environment variable**: Setup and teardown scripts receive `$CWT_ROOT` pointing to the repo root
- Integration tests for setup/teardown functionality
- Homebrew update instructions in deploy script

### Changed
- Setup now runs on first resume instead of during worktree creation
- Setup only runs once per worktree (tracked via `.cwt_needs_setup` marker)

## [0.1.0] - 2026-01-29

- Initial release
