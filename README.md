# wotr

Built on top of [cwt (claude-worktree)](https://github.com/bucket-robotics/claude-worktree) by [Bucket Robotics](https://github.com/bucket-robotics). cwt introduced the core idea: a TUI for managing git worktrees as isolated AI coding sessions. wotr extends it with a YAML config system, custom actions, shared resources, and a CLI.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/gtmax/wotr/main/install.sh | bash
```

Update to latest:

```bash
wotr update
```

## How wotr Works

wotr is a TUI + script execution harness for managing git worktrees as isolated AI coding sessions.

### Core Ideas

**Worktrees as sessions.** Each git worktree is a self-contained coding session — its own branch, its own files, its own AI agent conversation. wotr creates, lists, and switches between them.

**Persistent agent sessions.** Terminal-based AI agents (Claude Code, Aider, Codex) store conversations by directory path. Since each worktree has a fixed path, restarting your machine or switching away and back resumes the exact conversation where you left off. No session IDs to remember.

**Resource-constrained local dev.** Ideally each worktree would have its own dev server, its own database, its own containers. In practice, you can't bind port 3333 twice, you share one local Supabase instance, and running four copies of your Docker stack would melt your laptop memory. wotr tracks who owns what and lets you move shared resources between worktrees with a keypress.

**Script-driven customization.** wotr doesn't know your tech stack. All project-specific behavior — installing deps, starting servers, launching your AI agent — lives in `.wotr/config` as shell scripts. wotr just runs them and shows you the output.

wotr's terminal-native design assumes terminal-based AI coding agents. The switch hook suspends the TUI and hands the terminal to whatever CLI tool you configure. IDE-based tools (Cursor, Windsurf) that manage their own editor windows are not a natural fit.

### Design Principles

1.  **It's just Git:** Under the hood, we are just creating standard Git worktrees.
2.  **Native Environment:** When you enter a session, `wotr` suspends itself and runs your configured hook — typically launching a CLI agent or shell directly in that directory.
3.  **Zero Overhead:** We don't wrap the process. We don't intercept your commands. We don't run a background daemon. Your scripts, your aliases, and your workflow remain exactly the same.

## .wotr/config

A YAML file at the repository root. It tells wotr what to do when worktrees are created, entered, and how to manage shared resources. Three sections, all optional.

All scripts in `.wotr/config` are executed via bash, but can call external programs in any language — `python3 scripts/check_status.py`, `node scripts/setup.js`, a compiled Go binary, whatever. The inline script is just the entry point.

```yaml
hooks:       # lifecycle scripts (new worktree, switch to worktree)
actions:     # custom keyboard shortcuts
resources:   # shared infrastructure tracking
```

### Hooks

Hooks are shell scripts that run at key moments in a worktree's lifecycle.

**`new`** runs once when a worktree is first entered (after creation). Use it for setup: install dependencies, copy or symlink env files, prepare the workspace.

**`switch`** runs every time you enter a worktree. Use it to launch your AI agent.

After `new` completes, wotr automatically chains to `switch`.

Each hook is an array of steps:

```yaml
hooks:
  new:
    - bg: |
        wotr-default-setup
        pnpm install --frozen-lockfile
  switch:
    - bg: wotr-rename-tab
      stop_on_failure: false
    - fg: wotr-launch-claude
```

- **`bg:`** runs in the TUI log pane (non-interactive, output streams live)
- **`fg:`** suspends the TUI and takes the terminal (interactive)
- **`stop_on_failure: false`** — continue even if this step exits non-zero

Steps run in order. All steps before the first `fg:` run in the log pane. From the first `fg:` onward, the TUI is suspended.

### Resources

Resources represent shared local infrastructure that worktrees compete for.

Each resource has two scripts:
- **`acquire`** — claim the resource for a worktree (start a server, run migrations)
- **`inquire`** — check who currently owns it or whether a worktree is in sync

Resources come in two flavors:

**Exclusive** — only one worktree at a time. Port bindings, singleton services, Docker containers. Acquiring it stops it elsewhere and starts it here.

```yaml
resources:
  web-server:
    icon: 💻
    exclusive: true
    description: Dev server (port 3333)
    acquire: |
      bin/dev start
    inquire: |
      pid=$(lsof -ti :3333 -sTCP:LISTEN 2>/dev/null | head -1)
      if [ -z "$pid" ]; then
        wotr-output status=unowned
        exit 0
      fi
      # Walk up to git root to find owning worktree
      cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
      root="$cwd"
      while [ "$root" != "/" ] && [ ! -e "$root/.git" ]; do
        root=$(dirname "$root")
      done
      wotr-output status=owned owner="$root"
```

**Compatible** — each worktree independently in sync or not. Database migrations, file state. No ownership — just whether this worktree has what it needs.

```yaml
  db-schema:
    icon: 💾
    exclusive: false
    description: Database migrations applied
    acquire: |
      bin/dev db:migrate
    inquire: |
      # Check for pending migrations
      ...
      wotr-output status=compatible
      # or: wotr-output status=incompatible reason="3 pending"
```

wotr polls all resources every 60 seconds and shows ownership/status as icons next to each worktree in the TUI. Press a resource's shortcut key to acquire it for the selected worktree.

### Actions

Actions are custom keyboard shortcuts bound to commands you run against a worktree:

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
```

Actions use the same `bg:`/`fg:` step format as hooks.

Personal overrides go in `.wotr/config.local` (add to `.gitignore`).

## Architecture

```
┌──────────────────────────────────────────────┐
│                  wotr TUI                     │
│                                               │
│  Worktree list · Shortcuts · Log pane         │
│                                               │
└──────────────────┬───────────────────────────┘
                   │
     ┌─────────────┼─────────────┐
     │             │             │
     ▼             ▼             ▼
 Worktree     Hook/Action    Resource
 Manager      Engine         Manager
 ─────────    ───────────    ────────────
 create       runs bg/fg    polls inquire
 delete       steps from    runs acquire
 list         .wotr/config  maps icons
 discover                   to worktrees
     │             │             │
     │             └──────┬──────┘
     │                    │
     ▼                    ▼
 git worktree        .wotr/config
                     (your scripts)
```

The **Worktree Manager** handles git operations directly. The **Hook/Action Engine** and **Resource Manager** both execute scripts defined in `.wotr/config` — hooks and actions run your lifecycle/workflow scripts, while the resource manager runs your acquire and inquire scripts to track shared infrastructure.

## Log System

All script output flows to a unified log pane with two display modes:

- **Compact** (default) — shows only wotr's status messages. Script output is hidden but summarized: `Refreshing resource status... (12 lines)` with a dim preview of the last output line.
- **Verbose** — shows everything.

Toggle with `lv`. Copy log with `lc`. Copy log file path with `lp`.

On script failure: wotr auto-switches to verbose, pins the scroll to the error (new output won't push it off screen), and renders the error in red.

## Helper Scripts

wotr ships with optional helpers for common patterns:

| Script | Purpose |
|--------|---------|
| `wotr-default-setup` | Symlinks `.claude/` from repo root to worktree |
| `wotr-launch-claude` | Launches Claude Code with `--continue` (resumes last session) |
| `wotr-rename-tab` | Renames terminal tab to match branch name |
| `wotr-output` | Emits structured JSON for inquire scripts |

These are building blocks for `.wotr/config`, not requirements. Replace them with whatever fits your workflow.

## Usage

Run `wotr` in the root of any Git repository.

| Key | Action |
| :--- | :--- |
| **`n`** | **New** — create a worktree and launch `claude` in it |
| **`/`** | **Filter** — search by branch or folder name |
| **`Enter`** | **Resume** — suspend TUI, continue the last `claude` session in the worktree |
| **`s`** | **Shell** — quit TUI and cd into the worktree |
| **`d`** | **Delete** — remove worktree (checks for unmerged changes) |
| **`D`** | **Force Delete** — skip safety checks |
| **`j`/`k`** | Move selection down/up |
| **`Shift+R`** | Refresh worktree list |
| **`q`/`Esc`** | Quit |

Actions and resource shortcuts from `.wotr/config` are shown in the footer.

### CLI

```
wotr                          Launch TUI
wotr init                     Scaffold .wotr/config
wotr update                   Update to latest version
wotr acquire <resource>       Run resource acquire script
wotr inquire [resource]       Run resource inquire script(s)
wotr resources                List configured resources
wotr run <hook>               Run a config hook
wotr status [--json]          Show current branch
wotr list                     List all worktrees
wotr version                  Print version
```

## Under the Hood

*   Built in Ruby using `ratatui-ruby` for the UI.
*   Uses a simple thread pool for git operations so the UI doesn't freeze.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/gtmax/wotr.

## License

MIT
