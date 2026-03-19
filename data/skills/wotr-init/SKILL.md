---
name: wotr-init
description: |
  Generate a .wotr/config file for a project by analyzing its structure, dev scripts, Docker setup, and database tooling. Trigger: "set up wotr", "initialize wotr", "create wotr config", "wotr init"
---

# wotr-init

Generate a `.wotr/config` YAML file for a project so it works with [wotr](https://github.com/nicholaides/wotr) — a git-worktree manager with a TUI, resource tracking, and lifecycle hooks.

## Before You Start

Read these reference files (they are loaded automatically with the skill):

- `references/config-reference.md` — full `.wotr/config` spec (hooks, resources, environment vars, polling)
- `references/icon-guide.md` — emoji selection rules including the **VS-16 rendering bug**
- `references/resource-patterns.md` — reusable patterns for common resource types

## Workflow

Run four phases in order. After each phase, present findings and get user confirmation before proceeding.

### Phase 1: Discover

Analyze the project to understand what resources and hooks are needed.

**Search for these signals:**

| Signal | Where to look | What it tells you |
|--------|--------------|-------------------|
| Package manager | `package.json`, `Gemfile`, `pyproject.toml`, `go.mod` | Hook install commands |
| Dev server scripts | `bin/dev`, `package.json` scripts, `Makefile`, `Procfile` | Port-based resources |
| Docker Compose | `docker-compose.yml`, `compose.yml` | Container-based resources |
| Database tooling | `supabase/`, `prisma/`, `db/migrate/`, `alembic/` | Migration-based resources |
| Environment files | `.env*`, `.env.example` | Env sync hooks |
| Existing wotr config | `.wotr/config`, `.wotr/setup`, `.wotr/switch` | Migration from old format |
| CI config | `.github/workflows/`, `.gitlab-ci.yml` | Port numbers, test commands |
| Monorepo structure | `apps/`, `packages/`, `turbo.json`, `pnpm-workspace.yaml` | Nested paths for commands |

**Determine for each potential resource:**
1. Is it **exclusive** (only one worktree at a time) or **compatible** (each worktree independently)?
2. What **port** does it bind to (if any)?
3. How do you **acquire** it (start/claim)?
4. How do you **inquire** about it (check ownership/compatibility)?

Present a summary table:

```
Found:
  - Dev server on port 3000 (exclusive)
  - Supabase local DB with migrations (compatible)
  - Docker Compose services: worker, redis (exclusive)
  - pnpm monorepo with frozen lockfile
  - .env.development.local needs symlinking
```

### Phase 2: Propose

Generate a draft `.wotr/config` based on Phase 1 findings. Show the full YAML to the user.

**Rules for the proposal:**

1. **Hooks**
   - `new:` always starts with `wotr-default-setup` (symlinks `.claude/` directory)
   - Add package install command (`pnpm install --frozen-lockfile`, `bundle install`, etc.)
   - Symlink env files that can be shared; copy files Docker needs (Docker requires real files, not symlinks)
   - `switch:` should include `bg: wotr-rename-tab` (with `stop_on_failure: false`) then `fg: wotr-launch-claude`
   - Use `stop_on_failure: false` on best-effort steps like tab renaming

2. **Resources**
   - Use patterns from `references/resource-patterns.md` as starting points
   - Adapt port numbers, service names, and paths to match the actual project
   - For port-based exclusive resources: use `lsof` inquire pattern to find owner by walking to git root
   - For Docker Compose exclusive resources: use container name prefix to identify owning worktree
   - For DB migrations (compatible): check for pending migrations specific to each worktree

3. **Icons** (CRITICAL)
   - **NEVER use emoji that require U+FE0F (VS-16)** — they cause rendering artifacts in the TUI
   - Consult `references/icon-guide.md` for the safe/unsafe lists
   - Common safe choices: `💻` (servers), `💾` (databases), `🧪` (test), `🤖` (AI/bots), `⚡` (cache), `🐳` (Docker)
   - Each icon must be distinct within the config

4. **Resource names**
   - Use lowercase kebab-case
   - Keep names short — they generate keyboard shortcuts
   - Avoid names starting with reserved letters: `n`, `s`, `d`, `q`, `j`, `k`, `l`

### Phase 3: Refine

Ask the user targeted questions about anything uncertain:

- "I see ports 3000 and 3001 — are both dev servers or is one a different service?"
- "Should the switch hook restart all services or just the web server?"
- "The Docker Compose file has 5 services — which ones should be tracked as resources?"
- "Do you want db-schema as a resource? It shows incompatibility when migrations are pending."

Incorporate answers and show the updated config.

### Phase 4: Generate

Write the final `.wotr/config` file. Then:

1. Verify the file parses as valid YAML
2. Confirm icon safety: check every emoji in the config does NOT contain `\uFE0F`
3. Tell the user how to test:
   ```
   wotr              # Launch TUI — resources should appear in the table
   wotr resources    # List all resources with ownership status
   wotr inquire      # Run all inquire scripts and report status
   ```

## Important Technical Details

### The VS-16 Emoji Bug

The wotr TUI uses ratatui for terminal rendering. ratatui's diff-based update skips continuation cells (the second column of wide emoji) when only the style changes (e.g., selection highlight). Emoji requiring U+FE0F to be 2 columns wide will **disappear when the selection bar passes over them** and the highlight bar will overflow.

**Test**: An emoji is safe if its raw bytes do NOT include `\xEF\xB8\x8F` (UTF-8 for U+FE0F). In practice, avoid emoji from the Miscellaneous Symbols range (U+2600-U+26FF, U+2700-U+27BF) and some from U+1F5xx.

### inquire Script Contract

Every `inquire:` script MUST:
- Use `wotr-output` to emit structured status (not raw JSON, not echo)
- Exit with code 0 (non-zero = error state in TUI)
- For exclusive resources: output `status=owned owner="/path"` or `status=unowned`
- For compatible resources: output `status=compatible` or `status=incompatible reason="..."`

### Environment Variables in Scripts

Scripts receive:
- `WOTR_ROOT` — absolute path to the main repo checkout
- `WOTR_WORKTREE` — absolute path to the worktree being checked

### Worktree Path Convention

wotr creates worktrees at `../.worktrees/<repo-name>/<branch-name>` relative to the repo root. Docker Compose project names default to the directory name, which maps to the worktree name.

## Docker Acquire Best Practices

When generating acquire scripts for Docker Compose services, follow these three principles:

### 1. Stop-then-start for exclusive resources

`docker compose up -d` will fail if another worktree's containers hold the same ports. The acquire script must first identify and stop the same service from other worktrees by matching the Docker Compose project name prefix (which defaults to the directory name, mapping to the worktree name).

### 2. Wait for healthy with timeout

`docker compose up -d` returns immediately — the containers might crash-loop or take time to initialize. The acquire script must poll `docker inspect --format '{{.State.Health.Status}}'` with a timeout (typically 60s). Only report success when all containers reach `healthy`. This is critical: without it, wotr will report "acquired" while the service is actually broken.

### 3. Fail loudly on unhealthy

If the health check times out, dump the last N container log lines (`docker compose logs --tail=10 <service>`) and `exit 1`. wotr handles failures by:
- Auto-switching the log pane to verbose mode
- Pinning the scroll to the error (new output from resource polling won't push it off-screen)
- Rendering the error in red

This means the user immediately sees what went wrong without needing to manually check docker logs.

See `references/resource-patterns.md` for the complete Docker Compose pattern implementing all three principles.

## Edge Cases

- **Shared Supabase DB**: All worktrees share one local Supabase instance. Running `db:migrate` resets the DB, making other worktrees show as incompatible. This is expected — the `db-schema` resource tracks this.
- **Multiple ports**: If a service binds multiple ports, check the primary one in inquire. Note this in the description.
- **Background processes**: If `acquire` starts a background process, make sure it doesn't block. Use `&` or a wrapper script that backgrounds and logs.
- **Docker health checks**: Acquire scripts for Docker services should wait for containers to become healthy with a timeout. Exit non-zero if health check fails — wotr will show the failure in the log pane and auto-switch to verbose mode. See the Docker Compose pattern in `references/resource-patterns.md`.
- **Stopping other worktrees' containers**: When acquiring an exclusive Docker resource, stop the same containers from other worktrees first by matching the Docker Compose project name prefix.
- **Monorepo paths**: Commands like `supabase migration list` may need to `cd` into a sub-app directory. Use `$WOTR_WORKTREE/apps/web` not hardcoded paths.
