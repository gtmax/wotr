---
name: wotr-new
description: >-
  Spin up a fresh cmux workspace for a new task and drop into a new git worktree
  (via `wotr new`), branched from the repo's default branch. The branch name is
  derived from the input, which can be a Jira ticket (URL or key like SP-12345)
  or a free-form task description. Trigger: the `/wotr-new` command, or any
  request to "start a new worktree/workspace for <ticket-or-task>".
---

# wotr-new

Automate the "start working on a new thing" flow: open a new cmux workspace, and
inside it run `wotr new <branch>` to create a git worktree (branched from the
repo's default branch), run the repo's setup + switch hooks, and land in it.

This replaces the manual steps: create a cmux workspace → run `wotr` → press `n`.

## Input

`/wotr-new <arg>` where `<arg>` is **either**:

- **A Jira ticket** — a URL (`https://<site>.atlassian.net/browse/SP-12345`) or a
  bare key (`SP-12345`). Detected by the pattern `[A-Z][A-Z0-9]+-[0-9]+`.
- **A free-form task description** — e.g. `refactor the throttler dedup logic`.

The input only determines the **branch name**. Everything else is the same.

## Procedure

### 1. Build the branch name

The convention is: **Jira key first, then a short slug of the description.**

- **Jira input:** extract the key `KEY` (matches `[A-Z][A-Z0-9]+-[0-9]+`; pull it
  out of the URL if needed). If the `jira` CLI is available, fetch the summary and
  turn it into a slug:

  ```bash
  jira issue view "$KEY" --plain | head -40   # read the "# <summary>" line
  ```

  Craft `SLUG` from the summary yourself: lowercase, keep only `[a-z0-9]`, join
  words with `-`, drop filler words, cap at ~5–6 words. Branch = `${KEY}-${SLUG}`
  (e.g. `SP-75250-generic-triage-ga`). If the `jira` CLI is unavailable or the
  fetch fails, just use `KEY` as the branch (tell the user you couldn't fetch the
  summary).

- **Free-form input:** craft `SLUG` the same way from the text. Branch = `SLUG`
  (e.g. `refactor-throttler-dedup`).

Keep the branch to `[a-zA-Z0-9-]` — `wotr` sanitizes anything else to `_`, but a
clean slug is nicer. Do **not** include `/` (some CI downstreams break on it).

### 2. Locate cmux and the repo

```bash
CMUX="$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
[ -x "$CMUX" ] || { echo "cmux CLI not found"; exit 1; }
REPO="$(git rev-parse --show-toplevel)"   # run from the current session's cwd
```

`wotr new` discovers the main repo from any path inside it (including worktrees),
so `REPO` just needs to be somewhere in the target repository.

### 3. Open the workspace and create the worktree

```bash
# --switch tells `wotr new` to enter the worktree: run setup + the switch hook
# (which launches Claude) and drop into a shell. Without it, it only creates.
OUT="$("$CMUX" new-workspace --command "cd '$REPO' && wotr new '$BRANCH' --switch")"
# cmux prefixes every response with "OK "; the payload here is the new
# workspace's UUID. Strip the prefix and whitespace.
WS="$(printf '%s' "$OUT" | sed -E 's/^OK[[:space:]]+//' | tr -d '[:space:]')"

# CRITICAL: only use $WS as a handle if it's a valid UUID. A malformed handle
# makes cmux silently fall back to the CURRENTLY SELECTED workspace — i.e. it
# would rename/steal *this* session's workspace. Validate first.
if printf '%s' "$WS" | grep -qiE '^[0-9a-f-]{36}$'; then
  "$CMUX" rename-workspace  --workspace "$WS" "$BRANCH"   # switch hook also renames
  "$CMUX" select-workspace  --workspace "$WS"             # focus the new workspace
else
  echo "warning: couldn't parse new workspace id from: $OUT" >&2
fi
```

`wotr new` inside the new workspace will:
1. create the worktree (branch cut from `origin/<default-branch>`),
2. run the repo's `new` (setup) hook,
3. run the `switch` hook — which typically renames the tab and launches Claude,
4. leave a shell in the worktree.

If `$WS` didn't validate, do **not** pass it to any `--workspace` flag — skip the
rename/select entirely. The `switch` hook's `wotr-rename-tab` still names the
workspace correctly from inside it (it keys off `$CMUX_WORKSPACE_ID`, so it can't
hit the wrong one).

### 4. Report back

Tell the user the branch name, the ticket summary (if Jira), and that a new cmux
workspace has opened and is setting up / launching Claude. Keep it short.

## Notes

- **Portable:** no machine-specific paths beyond the cmux fallback. The `jira` CLI
  is optional — the skill degrades to using the bare key or the raw description.
- Do **not** drive the `wotr` TUI. `wotr new` is the headless CLI entry point.
- Confirm you're inside the intended git repo before running (check `REPO`).
