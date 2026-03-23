# Resource Patterns Library

Reusable patterns for common resource types. Adapt to the specific project.

---

## Port-Based Server (Exclusive)

For any service bound to a specific TCP port (dev servers, API servers, etc.).

```yaml
web-server:
  icon: 💻
  exclusive: true
  description: Dev server (port 3000)
  acquire: |
    npm run dev
  inquire: |
    pid=$(lsof -ti :3000 -sTCP:LISTEN 2>/dev/null | head -1)
    if [ -z "$pid" ]; then
      wotr-output status=unowned
      exit 0
    fi
    cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
    root="$cwd"
    while [ "$root" != "/" ] && [ ! -e "$root/.git" ]; do
      root=$(dirname "$root")
    done
    wotr-output status=owned owner="$root"
```

**Adapt**: Change port number, start command, icon.

**Variants**:
- Multiple ports: Check each, all must belong to same worktree
- Background process: Use `bin/dev start` style wrapper that backgrounds and logs

---

## Docker Compose Service (Exclusive)

For services running via Docker Compose.

```yaml
agents:
  icon: 🤖
  exclusive: true
  description: AI agent containers
  acquire: |
    # Stop containers from other worktrees first
    for name in service-a service-b; do
      old=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "\-${name}-[0-9]+$" | head -1)
      if [ -n "$old" ]; then
        old_project=$(echo "$old" | sed "s/-${name}-[0-9]*$//")
        current_project=$(basename "$PWD")
        if [ "$old_project" != "$current_project" ]; then
          echo "Stopping ${name} from project ${old_project}..."
          docker compose -p "$old_project" stop "$name" 2>/dev/null
        fi
      fi
    done
    docker compose up -d service-a service-b

    # Wait for containers to become healthy (timeout 60s)
    echo "Waiting for containers to become healthy..."
    for name in service-a service-b; do
      elapsed=0
      while [ $elapsed -lt 60 ]; do
        health=$(docker inspect --format '{{.State.Health.Status}}' \
          "$(docker compose ps -q "$name" 2>/dev/null)" 2>/dev/null)
        if [ "$health" = "healthy" ]; then
          echo "  $name: healthy"
          break
        elif [ "$health" = "" ]; then
          echo "  $name: container not found"
          exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
      done
      if [ "$health" != "healthy" ]; then
        echo "  $name: failed to become healthy within 60s (status: $health)"
        docker compose logs --tail=10 "$name" 2>/dev/null
        exit 1
      fi
    done
  inquire: |
    container=$(docker ps --filter health=healthy --format '{{.Names}}' 2>/dev/null \
      | grep -E "\-service-name-[0-9]+$" \
      | sed 's/-service-name-[0-9]*$//' \
      | head -1)
    if [ -z "$container" ]; then
      wotr-output status=unowned
      exit 0
    fi
    repo_name=$(basename "$WOTR_ROOT")
    if [ "$container" = "$repo_name" ]; then
      wotr-output status=owned owner="$WOTR_ROOT"
    else
      wotr-output status=owned owner="$(dirname "$WOTR_ROOT")/.worktrees/$repo_name/$container"
    fi
```

**Key points**:
- Use `--filter health=healthy` not `--filter status=running` to exclude crash-looping containers
- Docker Compose project name defaults to the directory name, which maps to the worktree
- Stop containers from other worktrees before starting — avoids port conflicts
- Wait for health checks with timeout — acquire fails visibly if containers crash-loop
- On failure, dump last 10 log lines so the error is visible in wotr's log pane

---

## Database Schema / Migrations (Compatible)

For databases shared across worktrees where each worktree has its own migration files.

```yaml
db-schema:
  icon: 💾
  exclusive: false
  description: Database migrations applied
  acquire: |
    bin/dev db:migrate
  inquire: |
    output=$(cd "$WOTR_WORKTREE/path/to/migrations" && migration-check-command 2>&1)
    pending=$(echo "$output" | grep -c 'pending')
    if [ "$pending" -gt 0 ]; then
      wotr-output status=incompatible reason="${pending} pending migrations"
    else
      wotr-output status=compatible
    fi
```

**Supabase variant**:
```yaml
  inquire: |
    output=$(cd "$WOTR_WORKTREE/apps/web" && supabase migration list --local 2>&1)
    pending=$(echo "$output" | awk '/\|/ {
      split($0, a, "|")
      gsub(/[[:space:]]/, "", a[1])
      gsub(/[[:space:]]/, "", a[2])
      if (a[1] ~ /^[0-9]+$/ && a[2] == "") print a[1]
    }')
    if [ -n "$pending" ]; then
      count=$(echo "$pending" | wc -l | tr -d ' ')
      wotr-output status=incompatible reason="${count} pending migrations"
    else
      wotr-output status=compatible
    fi
```

**Rails variant**:
```yaml
  inquire: |
    cd "$WOTR_WORKTREE"
    pending=$(bundle exec rails db:migrate:status 2>/dev/null | grep -c '^\s*down')
    if [ "$pending" -gt 0 ]; then
      wotr-output status=incompatible reason="${pending} pending migrations"
    else
      wotr-output status=compatible
    fi
```

---

## Redis / Memcached (Exclusive)

For cache services bound to a port.

```yaml
cache:
  icon: ⚡
  exclusive: true
  description: Redis (port 6379)
  acquire: |
    redis-server --daemonize yes
  inquire: |
    pid=$(lsof -ti :6379 -sTCP:LISTEN 2>/dev/null | head -1)
    if [ -z "$pid" ]; then
      wotr-output status=unowned
      exit 0
    fi
    # Redis is typically shared — report as owned by whoever started it
    cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
    root="$cwd"
    while [ "$root" != "/" ] && [ ! -e "$root/.git" ]; do
      root=$(dirname "$root")
    done
    wotr-output status=owned owner="$root"
```

---

## File Lock / PID File (Exclusive)

For resources tracked by a lock file or PID file.

```yaml
build-lock:
  icon: 🔧
  exclusive: true
  description: Build system lock
  acquire: |
    echo "$WOTR_WORKTREE" > .wotr/build.lock
    make build
  inquire: |
    lock=".wotr/build.lock"
    if [ ! -f "$WOTR_ROOT/$lock" ]; then
      wotr-output status=unowned
      exit 0
    fi
    owner=$(cat "$WOTR_ROOT/$lock")
    wotr-output status=owned owner="$owner"
```

---

## Environment File Sync (Compatible)

For checking if environment files are in sync.

```yaml
env-sync:
  icon: 🔑
  exclusive: false
  description: Environment files synced
  acquire: |
    cp "$WOTR_ROOT/.env.example" "$WOTR_WORKTREE/.env"
  inquire: |
    if [ ! -f "$WOTR_WORKTREE/.env" ]; then
      wotr-output status=incompatible reason="missing .env"
    else
      wotr-output status=compatible
    fi
```

---

## Hook Patterns

### Node.js / pnpm

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

### Python / Poetry

```yaml
hooks:
  new:
    - bg: |
        wotr-default-setup
        poetry install
  switch:
    - bg: wotr-rename-tab
      stop_on_failure: false
    - fg: wotr-launch-claude
```

### Ruby / Bundler

```yaml
hooks:
  new:
    - bg: |
        wotr-default-setup
        bundle install
  switch:
    - bg: wotr-rename-tab
      stop_on_failure: false
    - fg: wotr-launch-claude
```

### Config File Pattern

**Default: copy.** Each worktree gets its own independent copy so edits in one worktree don't affect others. Only symlink when there is a clear benefit — the file is actively maintained, changes frequently, and all worktrees must always see the latest version (e.g., shared credentials, tooling config that's never customized per-branch).

```yaml
hooks:
  new:
    - bg: |
        wotr-default-setup

        # Copy config/env files (default — worktree independence)
        for file in .env .env.test .env.development.local; do
          src="$WOTR_ROOT/$file"
          dst="$file"
          if [ -f "$src" ] && [ ! -e "$dst" ]; then
            cp "$src" "$dst"
            echo "  Copied $dst"
          fi
        done

        # Symlink files that must always stay in sync across worktrees
        # (e.g., shared credentials, actively maintained config never customized per-branch)
        for file in .credentials.json; do
          src="$WOTR_ROOT/$file"
          dst="$file"
          if [ -f "$src" ] && [ ! -e "$dst" ]; then
            ln -sf "$src" "$dst"
            echo "  Symlinked $dst"
          fi
        done
```
