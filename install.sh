#!/usr/bin/env bash
# Self-bootstrapping installer: when piped from curl, re-executes from a
# tempfile so that no subprocess can consume the remaining script lines.
if [ -z "$_WOTR_INSTALL_REEXEC" ]; then
  _WOTR_INSTALL_TMP=$(mktemp)
  cat > "$_WOTR_INSTALL_TMP"
  _WOTR_INSTALL_REEXEC=1 exec bash "$_WOTR_INSTALL_TMP"
fi
rm -f "$_WOTR_INSTALL_TMP" 2>/dev/null

set -e

REPO="gtmax/wotr"
REQUIRED_RUBY="3.2.0"
# Homebrew prefix: /opt/homebrew on Apple Silicon, /usr/local on Intel
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
BREW_RUBY="$BREW_PREFIX/opt/ruby/bin/ruby"
BREW_GEM="$BREW_PREFIX/opt/ruby/bin/gem"

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
    # Brew ruby is keg-only — add to PATH for this session and user's shell
    RUBY_BIN="$BREW_PREFIX/opt/ruby/bin"
    export PATH="$RUBY_BIN:$PATH"
    if [ -f "$HOME/.zshrc" ]; then
      if ! grep -q "$RUBY_BIN" "$HOME/.zshrc" 2>/dev/null; then
        echo "export PATH=\"$RUBY_BIN:\$PATH\"" >> "$HOME/.zshrc"
        echo "  Added $RUBY_BIN to ~/.zshrc"
      fi
    fi
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
  if [ -f "$gem_bin/$bin" ] && [ -d "$BREW_PREFIX/bin" ]; then
    ln -sf "$gem_bin/$bin" "$BREW_PREFIX/bin/$bin"
    echo "  Symlinked $bin → $BREW_PREFIX/bin/$bin"
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
LATEST_URL=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep '"browser_download_url"' \
  | grep '\.gem"' \
  | sed 's/.*"browser_download_url": "\(.*\)"/\1/' || true)

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
# ratatui_ruby publishes prebuilt binaries only for arm64-darwin-24 (macOS 15).
# All other platforms (Intel, older macOS) need to compile from source via Rust.
NEEDS_SOURCE=false
if [ "$(uname -m)" = "x86_64" ]; then
  NEEDS_SOURCE=true
elif [ "$(uname -s)" = "Darwin" ]; then
  DARWIN_MAJOR=$(uname -r | cut -d. -f1)
  if [ "$DARWIN_MAJOR" -lt 24 ] 2>/dev/null; then
    NEEDS_SOURCE=true
  fi
fi

if [ "$NEEDS_SOURCE" = "true" ]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "wotr needs Rust to compile a native dependency on this system."
    if command -v brew >/dev/null 2>&1; then
      printf "Install Rust via Homebrew? [Y/n] "
      read -r REPLY </dev/tty 2>/dev/null || REPLY=""
      if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        brew install rust
      else
        echo "Aborted."
        exit 1
      fi
    else
      echo "Please install Rust: https://rustup.rs"
      exit 1
    fi
  fi
  echo "Compiling ratatui_ruby from source (this may take a minute)..."
  "$GEM" install ratatui_ruby --platform ruby
fi
"$GEM" install --force "$GEM_FILE"
echo

# 3. Install binaries onto PATH
GEM_BIN=$("$GEM" environment | awk '/EXECUTABLE DIRECTORY/ {print $NF}')
symlink_bin "wotr" "$GEM_BIN"
# Helper scripts are bash/ruby — copy directly so the shell runs them, not RubyGems
GEM_DIR=$("$GEM" environment gemdir)
for script in wotr-default-setup wotr-output wotr-rename-tab; do
  SRC=$(ls "$GEM_DIR/gems/wotr-"*/exe/$script 2>/dev/null | tail -1)
  if [ -n "$SRC" ] && [ -d "$BREW_PREFIX/bin" ]; then
    cp "$SRC" "$BREW_PREFIX/bin/$script"
    chmod +x "$BREW_PREFIX/bin/$script"
    echo "  Installed $script → $BREW_PREFIX/bin/$script"
  fi
done
echo

# 4. User setup template
install_user_setup
echo

echo "wotr installed. Run 'wotr' in any git repo to get started."
