# wotr

Built on top of [cwt (claude-worktree)](https://github.com/bucket-robotics/claude-worktree) by [Bucket Robotics](https://github.com/bucket-robotics). cwt introduced the core idea: a TUI for managing git worktrees as isolated AI coding sessions. wotr extends it with a YAML config system, custom actions, shared resources, and a CLI.

---

There are a million tools for AI coding right now. Some wrap agents in Docker containers, others proxy every shell command you type, and some try to reinvent your entire IDE.

`wotr` is a simple tool built on a simple premise: **Git worktrees are the best way to isolate AI coding sessions, but they are annoying to manage manually.**

The goal of this tool is to be as unimposing as possible. We don't want to change how you work, we just want to make the "setup" part faster.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/gtmax/wotr/main/install.sh | bash
```

Update to latest:

```bash
wotr update
```

## How it works

The core of wotr is a minimal worktree manager — a TUI that creates, lists, and deletes git worktrees. On its own it does very little. The real power comes from the scripts you wire into it via `.wotr/config`: lifecycle hooks that run when worktrees are created or switched to, actions that bind keys to arbitrary commands, and resources that manage shared services across worktrees. wotr is the engine; your config is the logic.

1.  **It's just Git:** Under the hood, we are just creating standard Git worktrees.
2.  **Native Environment:** When you enter a session, `wotr` suspends itself and launches a native instance of `claude` (or your preferred shell) directly in that directory.
3.  **Zero Overhead:** We don't wrap the process. We don't intercept your commands. We don't run a background daemon. Your scripts, your aliases, and your workflow remain exactly the same.

## Features

*   **Fast Management:** Create, switch, and delete worktrees instantly.
*   **Safety Net:** wotr checks for unmerged changes before you delete a session, so you don't accidentally lose work.
*   **Session Persistence:** Claude conversations are tied to worktree paths, so they survive restarts. Reboot your machine, re-enter a worktree, and your conversation picks up right where you left off.
*   **Auto-Setup:** Symlinks your `.env` and `node_modules` out of the box via `wotr-default-setup`. Customize with `.wotr/config`.
*   **Custom Actions:** Define keybindings that launch editors, run tests, or any command against a worktree.
*   **Shared Resources:** Local dev is resource-constrained — you can't run a separate web server, database, and Docker stack for every worktree. wotr lets you define exclusive resources and switch them between worktrees with a single keypress, so the right branch always owns the right services.

## Configuration

Create `.wotr/config` in your repo root (or run `wotr init`):

### Hooks

Two lifecycle hooks run at key moments:

*   **`new`** — runs once when a worktree is first created. Use it to install dependencies, symlink config files, or anything else needed to make the worktree functional. wotr ships a built-in helper, `wotr-default-setup`, which symlinks your `.claude/` directory (so Claude Code settings, skills, and CLAUDE.md carry over) while keeping `settings.local.json` as an isolated copy. Call it from your hook and add project-specific steps after it.
*   **`switch`** — runs every time you switch context to a worktree. Typically used to stop services owned by the previous worktree and start them for the new one.

```yaml
hooks:
  new: |
    wotr-default-setup
    pnpm install --frozen-lockfile
  switch: |
    bin/dev stop-all
    bin/dev start
```

### Actions

Actions bind keys to commands you run against the selected worktree. Two modes:

*   **`switch_to`** — suspends the TUI and hands the terminal to the command (e.g. an editor). When the command exits, the TUI resumes.
*   **`run`** — runs in the background while the TUI stays open, with output shown in a log pane.

If both are present, `run` executes first as preparation, then `switch_to` takes over.

```yaml
actions:
  editor:
    key: e
    switch_to: nvim .
  test:
    key: t
    run: pnpm test
```

### Resources

A dev machine has limited capacity — you typically can't run a separate web server, database, and Docker stack for every worktree simultaneously. Resources let you declare these shared services and manage which worktree owns them.

Each resource has two scripts:

*   **`inquire`** — checks the current state of the resource. Runs periodically in the background. The script uses `wotr-output` to report status: `status=unowned` (nobody owns it), `status=owned owner=<path>` (owned by a specific worktree), or `status=compatible` (non-exclusive, available to this worktree).
*   **`acquire`** — takes ownership of the resource for the selected worktree. Typically stops the service elsewhere and starts it here.

Resources can be **exclusive** or **non-exclusive**:

*   **Exclusive** (e.g. a web server bound to a port) — only one worktree can own it at a time. The inquire script reports `status=owned owner=<path>` to indicate which worktree has it, and the TUI shows the resource icon next to that worktree.
*   **Non-exclusive** (e.g. a database schema) — multiple worktrees can be compatible with the current state. The inquire script reports `status=compatible` for each worktree whose code matches the current DB schema, and the TUI shows the icon next to all compatible worktrees. This is useful for resources like database migrations where you need to know which branches are safe to work on without running a migration first.

```yaml
resources:
  web-server:
    icon: 💻
    exclusive: true
    description: Web dev server (port 3333)
    acquire: |
      bin/dev start
    inquire: |
      pid=$(lsof -ti :3333 -sTCP:LISTEN 2>/dev/null | head -1)
      if [ -z "$pid" ]; then
        wotr-output status=unowned
        exit 0
      fi
      wotr-output status=owned owner="$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')"
  db-schema:
    icon: 💾
    exclusive: false
    description: Database schema compatibility
    acquire: |
      bin/dev db:migrate
    inquire: |
      bin/dev db:check-schema && wotr-output status=compatible || wotr-output status=incompatible
```

Personal overrides go in `.wotr/config.local` (add to `.gitignore`).

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
