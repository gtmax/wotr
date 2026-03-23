# wotr Config Reference

## File Location

`.wotr/config` — YAML file at repository root.

## Top-Level Structure

```yaml
hooks:
  new:
    - bg: |
        # Setup steps — run in TUI log pane after worktree creation
  switch:
    - fg: |
        # Interactive step — suspends TUI, takes the terminal

actions:
  action-name:
    key: <letter>
    steps:
      - bg: # runs in background, output in log pane
      - fg: # suspends TUI, takes terminal

resources:
  resource-name:
    icon: <emoji>
    exclusive: true|false
    description: "Human-readable description"
    acquire: |
      # Shell script — sets up or claims the resource
    inquire: |
      # Shell script — checks resource status (must output JSON via wotr-output)
```

All sections (`hooks`, `actions`, `resources`) are optional.

## Hooks

### `new`

Runs inside the newly created worktree directory. Typical uses:
- Install dependencies (`npm ci`, `pnpm install`, `bundle install`)
- Copy config/env files from the main checkout (default — gives each worktree independence)
- Symlink files only when they must always stay in sync across all worktrees (e.g., shared credentials, actively maintained tooling config that's never customized per-branch)
- Run `wotr-default-setup` first to symlink `.claude/` contents

### `switch`

Runs when the user switches focus to an existing worktree. Typical uses:
- Restart dev servers pointed at this worktree
- Reload environment

### Hook Format

Hooks are arrays of steps, each either `bg:` or `fg:`:

```yaml
hooks:
  new:
    - bg: wotr-default-setup && pnpm install
  switch:
    - bg: wotr-rename-tab
      stop_on_failure: false
    - fg: wotr-launch-claude
```

- **`bg:`** steps run in the TUI log pane (non-interactive). The TUI stays active.
- **`fg:`** steps suspend the TUI and take the terminal (interactive).

Steps before the first `fg:` step run in the log pane. From the first `fg:` onward, all steps run with the TUI suspended.

After the `new` hook completes, wotr automatically runs the `switch` hook.

### Step Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `stop_on_failure` | boolean | `true` | If `false`, continue to next step even if this one exits non-zero |

Use `stop_on_failure: false` for best-effort steps like tab renaming that shouldn't block the workflow.

### Hook Execution Order (for `new`)

1. `.wotr/config` `new:` hook (if defined)
2. Default symlinks (`.env`, `node_modules`) — ONLY if no hook ran

## Resources

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `icon` | string | `•` | Single emoji for TUI display |
| `exclusive` | boolean | `false` | Whether only one worktree can own it |
| `description` | string | — | Shown in resource legend |
| `acquire` | string | — | Shell script to claim/setup the resource |
| `inquire` | string | — | Shell script to check status (outputs JSON) |

### Exclusive vs Compatible

**Exclusive** (`exclusive: true`):
- Only one worktree at a time. Think: port bindings, singleton services.
- `inquire` must report who owns it.
- `acquire` typically stops the resource elsewhere, then starts it here.

**Compatible** (`exclusive: false`):
- Each worktree independently compatible or not. Think: DB migrations, file state.
- `inquire` reports whether this worktree is compatible.
- `acquire` makes this worktree compatible (e.g., runs migrations).

### inquire Script Output

Scripts must use `wotr-output` to emit JSON:

```bash
# Exclusive resource — currently owned by a worktree
wotr-output status=owned owner="/path/to/worktree"

# Exclusive resource — not running / not owned
wotr-output status=unowned

# Compatible resource — this worktree is in sync
wotr-output status=compatible

# Compatible resource — this worktree is out of sync
wotr-output status=incompatible reason="3 pending migrations"
```

Exit code must be 0. Non-zero = error state.

### Environment Variables Available to Scripts

| Variable | Description |
|----------|-------------|
| `WOTR_ROOT` | Absolute path to the main repo checkout |
| `WOTR_WORKTREE` | Absolute path to the worktree being checked |

### Built-in Helper Scripts

**`wotr-default-setup`** — for `new` hooks. Symlinks `.claude/` directory contents from root to worktree, except `settings.local.json` which is copied (for per-worktree isolation).

**`wotr-launch-claude`** — for `switch` hooks. Launches Claude Code with `--continue` to resume the last conversation in that worktree. Falls back to a fresh session if no prior conversation exists.

**`wotr-rename-tab`** — for `switch` hooks. Renames the terminal tab/workspace to match the current branch name. Supports cmux terminals. Silent no-op on unsupported terminals. Use with `stop_on_failure: false` since tab renaming is best-effort.

```yaml
hooks:
  new:
    - bg: wotr-default-setup && npm ci
  switch:
    - bg: wotr-rename-tab
      stop_on_failure: false
    - fg: wotr-launch-claude
```

## Actions

Actions bind keyboard shortcuts to commands run against the selected worktree.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | Single letter keybinding (must not conflict with reserved keys) |
| `steps` | array | Array of `bg:` and `fg:` steps |

### Step Types

- **`bg:`** — runs while TUI stays open, output in log pane
- **`fg:`** — suspends TUI, hands terminal to the command

If any step is `fg:`, all steps run sequentially with TUI suspended.

### Example

```yaml
actions:
  editor:
    key: e
    steps:
      - fg: nvim .
  test:
    key: t
    steps:
      - bg: pnpm test
  deploy:
    key: p
    steps:
      - bg: pnpm build
      - fg: bin/deploy
```

## Resource Polling

- Resources are polled every 60 seconds
- Exclusive: stops checking other worktrees once owner is found
- Compatible: checks each worktree independently
- Icons appear in the TUI's "resources" column per worktree

## Keyboard Shortcuts

Each resource gets an auto-assigned single-letter shortcut from its name. Pressing the shortcut on a selected worktree runs `acquire` for that resource.

Reserved letters: `n`, `/`, `Enter`, `s`, `d`, `Esc`, `q`, `j`, `k`, `l`, `D`, `R`
