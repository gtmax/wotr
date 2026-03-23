---
name: wotr-config
description: |
  Generate or update a .wotr/config file for a project by analyzing its structure, dev scripts, Docker setup, and database tooling. Trigger: any mention of "wotr" — this is a unique tool name and this skill should handle all wotr-related requests including setup, config generation, explanation, troubleshooting, and resource management.
---

# wotr-config

Generate a `.wotr/config` YAML file for a project so it works with [wotr](https://github.com/nicholaides/wotr) — a git-worktree manager with a TUI, resource tracking, and lifecycle hooks.

## Before You Start

Read these reference files (they are loaded automatically with the skill):

- `references/config-reference.md` — full `.wotr/config` spec (hooks, resources, environment vars, polling)
- `references/icon-guide.md` — emoji selection rules including the **VS-16 rendering bug**
- `references/resource-patterns.md` — reusable patterns for common resource types

## Workflow

Run three phases in order. After each phase, present findings and get user confirmation before proceeding.

### Phase 1: Discover & Propose

This phase has two parts: silently analyze the project, then present findings with educational context so the user understands what you're proposing and why.

**IMPORTANT: Do not use wotr-specific terminology in any user-facing output before explaining it.** Terms like "hooks", "resources", "acquire", "inquire", "exclusive", and "compatible" are wotr concepts that need introduction first. In particular, do not start your response with phrases like "Let me analyze what resources and hooks are needed" — the user doesn't know what those mean yet. Instead, say something like "Let me analyze the project to figure out how to set up wotr."

#### Part A: Discover (silent — no user-facing output)

Analyze the project to understand its structure, dev workflow, and infrastructure.

**Search for these signals:**

| Signal | Where to look | What it tells you |
|--------|--------------|-------------------|
| Package manager | `package.json`, `Gemfile`, `pyproject.toml`, `go.mod` | Hook install commands |
| Dev server scripts | `bin/dev`, `package.json` scripts, `Makefile`, `Procfile` | Port-based resources |
| Docker Compose | `docker-compose.yml`, `compose.yml` | Container-based resources (see filtering rules below) |
| Database tooling | `supabase/`, `prisma/`, `db/migrate/`, `alembic/`, `infra/migrations/`, migration Docker services | Migration-based resources — find migration files, tracking table, and apply command |
| Environment files | `.env*`, `.env.example` | Env sync hooks |
| Existing wotr config | `.wotr/config`, `.wotr/setup`, `.wotr/switch` | Migration from old format |
| CI config | `.github/workflows/`, `.gitlab-ci.yml` | Port numbers, test commands |
| Monorepo structure | `apps/`, `packages/`, `turbo.json`, `pnpm-workspace.yaml` | Nested paths for commands |

##### Docker Compose Resource Filtering

**Not every Docker Compose service should become a wotr resource.** Only model a Docker service as a wotr resource if the code/configuration for that service comes from the repo being analyzed — meaning the worktree change would actually affect that service's behavior.

Services like PostgreSQL, Redis/Valkey, Elasticsearch, Jaeger, etc. that are pulled as stock images and used as shared infrastructure do **not** need to be wotr resources. They are dependencies that all worktrees share equally — switching worktrees doesn't change anything about them.

**Model as a resource when:**
- The repo contains the Dockerfile or custom image build for the service
- The repo contains app code that runs inside the container (e.g., a worker service built from the repo)
- Switching worktrees means the container needs to run different code

**Do NOT model as a resource when:**
- The service uses a stock image (postgres, redis, elasticsearch, etc.)
- The service is shared infrastructure that doesn't change per-worktree
- The service is a dev tool (Jaeger, Kibana, Langfuse, etc.)
- The service is a **database or datastore** (PostgreSQL, Elasticsearch, Redis, Valkey, ClickHouse, etc.) — these are shared by all worktrees. Having a bound port does NOT make a datastore an exclusive resource. However, the *data schema* inside a datastore is often a **compatible resource** — see "Migration-File Based Schema Detection" below. If schema changes are applied purely from the application layer (e.g., ORM auto-migrations at startup, application-level index creation with no migration files), do NOT model the schema as a resource — there's no reliable way to inquire about it.

**Determine for each potential resource:**
1. Is it **exclusive** (only one worktree at a time) or **compatible** (each worktree independently)?
2. What **port** does it bind to (if any)?
3. How do you **acquire** it (start/claim)?
4. How do you **inquire** about it (check ownership/compatibility)?

##### Migration-File Based Schema Detection

**Any project that uses migration files can have its database schema modeled as a compatible resource**, regardless of which specific migration tool is used. The principle is universal: migration files on disk can be compared to the migration tracking table in the database.

**During discovery, identify:**
1. **Where migration files live** — e.g., `infra/migrations/`, `db/migrate/`, `migrations/`, `alembic/versions/`
2. **Which table tracks applied migrations** — e.g., `schema_migrations`, `flyway_schema_history`, `alembic_version`, `migration_versions`. Check the migration tool's documentation or the Docker Compose setup to find this.
3. **How migrations are applied** — e.g., `make db-migrate`, `rails db:migrate`, `alembic upgrade head`, or a Docker container that runs on `docker compose up`. This becomes the `acquire` command.

**The `inquire` script** compares migration files in `$WOTR_WORKTREE` to the tracking table:
- List migration files in the worktree's migration directory (by filename/timestamp)
- Query the tracking table for applied migrations
- If any migration files in the worktree are not yet applied, report `status=incompatible` with the count
- If all are applied, report `status=compatible`

This works because each worktree may have different migration files (e.g., a feature branch adding a new migration), and running migrations from one worktree can make other worktrees incompatible if they expect different schema states.

**Do NOT model schema as a resource when:**
- Schema changes happen implicitly at application startup (ORM auto-migrations, auto-index creation)
- There are no migration files to compare against
- The migration system has no tracking table accessible via CLI/SQL

Do NOT present a raw discovery summary to the user. Instead, proceed directly to Part B and weave findings into the educational explanation.

#### Part B: Propose (user-facing — educate then present plan)

**Do NOT show the raw YAML to the user** (unless they ask for it). Instead, explain in plain language what you plan to configure and why. Assume the user has no prior knowledge of wotr — this is your opportunity to teach them how it works.

**CRITICAL: Educate before referencing concepts.** Every wotr-specific term (hooks, resources, acquire, inquire, exclusive, compatible) must be explained *before* it is first used. Never assume the user knows what these mean. The structure below ensures concepts are introduced in the right order.

**Structure your explanation like this:**

1. **wotr and worktrees**: Explain that wotr manages git worktrees — isolated copies of the repo where you can work on different branches simultaneously without stashing or switching. Each worktree has its own working directory but shares the same git history.

2. **The `.wotr/config` file**: Explain that this YAML file lives at the repo root and tells wotr how to manage worktrees. It has three optional sections:
   - **Hooks** — shell scripts that run automatically at key moments (creating a worktree, switching to one)
   - **Resources** — processes (like a dev server) or data states (like a DB schema) that worktrees affect and that wotr tracks per-worktree
   - **Actions** — keyboard shortcuts in wotr's TUI for common tasks

3. **Hooks you'll configure**: For each hook, inline the hook type explanation at the start of the description, then immediately describe what you chose to configure for this project. Do NOT list hook types separately from what they'll do. For example:

   - **`new` hook** (runs once when a worktree is first created): "This will install dependencies and copy config files so the worktree is ready to use immediately. Specifically, it will: 1) run `wotr-default-setup` to symlink `.claude/` settings, 2) run `pnpm install`, 3) copy `.env` from the main checkout..."
   - **`switch` hook** (runs each time you switch focus to an existing worktree): "This will rename your terminal tab to match the branch name and launch Claude Code to resume where you left off."

   The key principle: the user should learn what each hook type *is* from seeing what it *does* in their project, not from a separate abstract explanation.

4. **Resources you'll configure** (if any): First explain the resource concept — resources are processes (like a dev server) or data states (like a DB schema) that worktrees affect. wotr tracks the state of each resource per worktree and shows it in the TUI, so you always know which worktrees are ready to use.

   There are two kinds of resources:
   - **Exclusive**: A process or service where only one instance can exist in the system at a time (e.g., a web server bound to a specific port). At any point, it belongs to a specific worktree. When you acquire it for one worktree, the previous owner loses it.
   - **Compatible**: A shared state (like a DB schema) where multiple worktrees can independently be compatible or incompatible with the current state. For example, after running migrations from one worktree, other worktrees with different migration files may become incompatible.

   Each resource has two shell scripts:
   - **`inquire`** — checks the current state of the resource. For exclusive resources, it reports which worktree currently owns it. For compatible resources, it reports whether this worktree is compatible. wotr runs this periodically to keep the TUI up to date.
   - **`acquire`** — takes action to claim or fix the resource (e.g., "start the dev server" or "run pending migrations"). You trigger this from the TUI when a resource needs attention.

   For each resource you plan to configure, explain what it tracks and why it matters for this project.

5. **What you're NOT configuring** (if relevant): Mention Docker Compose services or other infrastructure you found but chose not to model as resources, and briefly explain why (shared infrastructure that doesn't change per-worktree).

6. **Actions you'll configure** (if any): Explain what each action does and its keyboard shortcut.

**Rules for the config you'll generate:**

1. **Hooks**
   - `new:` always starts with `wotr-default-setup` (symlinks `.claude/` directory)
   - Add package install command (`pnpm install --frozen-lockfile`, `bundle install`, etc.)
   - **Copy config/env files by default** — each worktree gets its own independent copy, avoiding cross-worktree side effects when a file is edited. Only symlink when there is a clear benefit: the file is actively maintained, changes frequently, and all worktrees must always see the latest version (e.g., shared credentials, tooling config that's never customized per-branch). When in doubt, copy.
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

### Phase 2: Refine

After explaining your plan, ask the user targeted questions about anything uncertain:

- "I see ports 3000 and 3001 — are both dev servers or is one a different service?"
- "Should the switch hook restart all services or just the web server?"
- "Do you want db-schema as a resource? It shows incompatibility when migrations are pending."
- "Are there any other tasks you commonly run that would be useful as keyboard shortcuts?"

Incorporate answers and update your plan. You do not need to re-explain the full plan — just summarize what changed.

### Phase 3: Generate

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
