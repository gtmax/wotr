#!/usr/bin/env bash
set -e

REPO="gtmax/wotr"
REQUIRED_RUBY="3.2.0"
BREW_RUBY="/opt/homebrew/opt/ruby/bin/ruby"
BREW_GEM="/opt/homebrew/opt/ruby/bin/gem"

# ── Helpers ────────────────────────────────────────────────────────────────────

ruby_meets_requirement() {
  # Returns 0 if $1 >= $2 (semantic version compare)
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

find_ruby() {
  for candidate in "$(which ruby 2>/dev/null)" "$BREW_RUBY"; do
    [ -x "$candidate" ] || continue
    version=$("$candidate" -e 'print RUBY_VERSION' 2>/dev/null)
    if ruby_meets_requirement "$version" "$REQUIRED_RUBY"; then
      echo "$candidate"
      return
    fi
  done
}

ensure_ruby() {
  RUBY=$(find_ruby)
  if [ -n "$RUBY" ]; then
    GEM=$(dirname "$RUBY")/gem
    return 0
  fi

  echo "wotr requires Ruby $REQUIRED_RUBY+, which was not found."
  if ! command -v brew >/dev/null 2>&1; then
    echo "Please install Ruby $REQUIRED_RUBY+ manually: https://www.ruby-lang.org/en/documentation/installation/"
    exit 1
  fi

  printf "Install Ruby via Homebrew? [Y/n] "
  read -r REPLY </dev/tty 2>/dev/null || REPLY=""
  if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    brew install ruby
    RUBY="$BREW_RUBY"
    GEM="$BREW_GEM"
  else
    echo "Aborted."
    exit 1
  fi
}

symlink_bin() {
  local bin="$1"
  local gem_bin="$2"
  if [ -f "$gem_bin/$bin" ] && [ -d "/opt/homebrew/bin" ]; then
    ln -sf "$gem_bin/$bin" "/opt/homebrew/bin/$bin"
    echo "  Symlinked $bin → /opt/homebrew/bin/$bin"
  fi
}

install_user_setup() {
  if [ ! -f "$HOME/.wotr/setup" ]; then
    mkdir -p "$HOME/.wotr"
    cat > "$HOME/.wotr/setup" <<'SETUP'
#!/bin/bash
# ~/.wotr/setup — runs when creating a new worktree in any repo.
#
# wotr-default-setup symlinks .env, node_modules, and .claude from the repo root.
# Remove it to opt out. Add your own steps below.
wotr-default-setup
SETUP
    chmod +x "$HOME/.wotr/setup"
    echo "  Created ~/.wotr/setup"
  else
    echo "  ~/.wotr/setup already exists, skipping."
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Installing wotr..."
echo

# 1. Ruby
ensure_ruby
echo "Using Ruby $("$RUBY" -e 'print RUBY_VERSION')"
echo

# 2. Download and install gem from latest GitHub release
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading latest gem from github.com/$REPO..."
LATEST_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"browser_download_url"' \
  | grep '\.gem"' \
  | sed 's/.*"browser_download_url": "\(.*\)"/\1/')

if [ -z "$LATEST_URL" ]; then
  # No release yet — build from source
  echo "No release found, building from source..."
  if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is required to build from source." >&2; exit 1
  fi
  git clone --depth=1 "https://github.com/$REPO.git" "$TMP_DIR/wotr"
  cd "$TMP_DIR/wotr"
  "$RUBY" -S gem build wotr.gemspec
  GEM_FILE=$(ls wotr-*.gem)
else
  curl -fsSL "$LATEST_URL" -o "$TMP_DIR/wotr.gem"
  GEM_FILE="$TMP_DIR/wotr.gem"
fi

echo "Installing gem..."
"$GEM" install --force "$GEM_FILE"
echo

# 3. Install binaries onto PATH
GEM_BIN=$("$GEM" environment | awk '/EXECUTABLE DIRECTORY/ {print $NF}')
symlink_bin "wotr" "$GEM_BIN"
# Helper scripts are bash/ruby — copy directly so the shell runs them, not RubyGems
GEM_DIR=$("$GEM" environment gemdir)
for script in wotr-default-setup wotr-output; do
  SRC=$(ls "$GEM_DIR/gems/wotr-"*/exe/$script 2>/dev/null | tail -1)
  if [ -n "$SRC" ] && [ -d "/opt/homebrew/bin" ]; then
    cp "$SRC" "/opt/homebrew/bin/$script"
    chmod +x "/opt/homebrew/bin/$script"
    echo "  Installed $script → /opt/homebrew/bin/$script"
  fi
done
echo

# 4. User setup template
install_user_setup
echo

echo "wotr installed. Run 'wotr' in any git repo to get started."
