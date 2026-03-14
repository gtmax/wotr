# wotr

Built on top of [cwt (claude-worktree)](https://github.com/bucket-robotics/claude-worktree) by [Bucket Robotics](https://github.com/bucket-robotics). cwt introduced the core idea: a TUI for managing git worktrees as isolated AI coding sessions. wotr extends it with a YAML config system, custom actions, shared resources, and a CLI.

---

There are a million tools for AI coding right now. Some wrap agents in Docker containers, others proxy every shell command you type, and some try to reinvent your entire IDE.

`wotr` is a simple tool built on a simple premise: **Git worktrees are the best way to isolate AI coding sessions, but they are annoying to manage manually.**

The goal of this tool is to be as unimposing as possible. We don't want to change how you work, we just want to make the "setup" part faster.

## How it works

When you use `wotr`, you are just running a TUI (Terminal User Interface) to manage folders.

1.  **It's just Git:** Under the hood, we are just creating standard Git worktrees.
2.  **Native Environment:** When you enter a session, `wotr` suspends itself and launches a native instance of `claude` (or your preferred shell) directly in that directory.
3.  **Zero Overhead:** We don't wrap the process. We don't intercept your commands. We don't run a background daemon. Your scripts, your aliases, and your workflow remain exactly the same.

## Features

*   **Fast Management:** Create, switch, and delete worktrees instantly.
*   **Safety Net:** wotr checks for unmerged changes before you delete a session, so you don't accidentally lose work.
*   **Auto-Setup:** Symlinks your `.env` and `node_modules` out of the box via `wotr-default-setup`. Customize with `.wotr/config`.
*   **Custom Actions:** Define keybindings that launch editors, run tests, or any command against a worktree.
*   **Shared Resources:** Track exclusive resources (dev servers, databases, Docker containers) across worktrees.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/gtmax/wotr/main/install.sh | bash
```

Update to latest:

```bash
wotr update
```

## Configuration

Create `.wotr/config` in your repo root (or run `wotr init`):

```yaml
hooks:
  new: |
    wotr-default-setup
    pnpm install --frozen-lockfile
  switch: |
    bin/dev stop-all
    bin/dev start

actions:
  editor:
    key: e
    switch_to: nvim .
  test:
    key: t
    run: pnpm test

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
