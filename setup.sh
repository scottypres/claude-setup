#!/usr/bin/env bash
# claude-setup — install Claude Code + 1Password MCP + commonly-used CLIs on a fresh machine.
# Idempotent. Works on Mac and apt-based Linux. Run after signing into 1Password.

set -euo pipefail

# --- pretty output ---
c_blue=$'\033[1;34m'; c_red=$'\033[1;31m'; c_yellow=$'\033[1;33m'; c_green=$'\033[1;32m'; c_off=$'\033[0m'
log()  { printf '%s[%s]%s %s\n'  "$c_blue"   "$(date +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$c_yellow" "$(date +%H:%M:%S)" "$c_off" "$*" >&2; }
err()  { printf '%s[%s] ERR%s  %s\n' "$c_red"    "$(date +%H:%M:%S)" "$c_off" "$*" >&2; }
ok()   { printf '%s[%s] OK%s   %s\n' "$c_green"  "$(date +%H:%M:%S)" "$c_off" "$*"; }

# --- overrideable config ---
SA_TOKEN_REF="${SA_TOKEN_REF:-op://Development/1Password — Service Account Token/password}"
GH_PAT_REF="${GH_PAT_REF:-op://Development/GitHub — Personal Access Token/password}"
VERCEL_TOKEN_REF="${VERCEL_TOKEN_REF:-op://Development/Vercel — Personal Access Token/password}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# --- platform detect ---
case "${OSTYPE:-}" in
  darwin*)  PLATFORM=mac ;;
  linux*)   PLATFORM=linux ;;
  *)        err "Unsupported platform: ${OSTYPE:-unknown}"; exit 1 ;;
esac
log "Platform: $PLATFORM"

have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$PLATFORM" = linux ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
  SUDO="sudo"
fi
# SUDO_E expands to "sudo -E" when sudo is in use, empty otherwise. Used for
# pipe-into-bash installers that need preserved env (e.g. NodeSource).
SUDO_E="${SUDO:+sudo -E}"
# Silence debconf prompts on apt-based distros for cleaner output
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Tier 2: install prerequisites
# =============================================================================
log "=== Tier 2: install prerequisites ==="

if [ "$PLATFORM" = mac ]; then
  if ! have brew; then
    log "Installing Homebrew (will prompt for sudo)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if   [ -d /opt/homebrew ];      then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -d /usr/local/Homebrew ]; then eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  for pkg in jq node gh; do
    if ! have "$pkg"; then log "brew install $pkg"; brew install "$pkg"; else ok "$pkg already present"; fi
  done
  if ! have op; then log "brew install --cask 1password-cli"; brew install --cask 1password-cli; else ok "op already present"; fi
  if [ ! -d "/Applications/1Password.app" ]; then
    log "brew install --cask 1password (desktop app, for Touch ID + CLI integration)"
    brew install --cask 1password || warn "Could not install 1P app; continuing"
  else
    ok "1Password app already installed"
  fi

elif [ "$PLATFORM" = linux ]; then
  if ! have apt-get; then
    err "No apt-get found. This script supports apt-based Linux only. Install jq/node/op/gh manually."
    exit 1
  fi
  log "apt update + install core packages..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq curl ca-certificates gnupg jq git tmux

  # Node.js 22 LTS via NodeSource if missing
  if ! have node; then
    log "Installing Node.js 22 LTS via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO_E bash -
    $SUDO apt-get install -y -qq nodejs
  else
    ok "node: $(node --version)"
  fi

  # 1Password CLI via 1P apt repo
  if ! have op; then
    log "Installing 1Password CLI from 1password apt repo..."
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
      | $SUDO gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main" \
      | $SUDO tee /etc/apt/sources.list.d/1password.list >/dev/null
    $SUDO mkdir -p /etc/debsig/policies/AC2D62742012EA22/
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
      | $SUDO tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null
    $SUDO mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
      | $SUDO gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq 1password-cli
  else
    ok "op: $(op --version)"
  fi

  # GitHub CLI via gh apt repo
  if ! have gh; then
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
    $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq gh
  else
    ok "gh: $(gh --version | head -1)"
  fi
fi

# Verify all prereqs are now in place
for c in git jq op node npm gh tmux; do
  have "$c" || { err "Missing required tool after install: $c"; exit 1; }
done
ok "All prereq tools present"

# =============================================================================
# 1Password CLI signin check
# =============================================================================
log "=== Verifying 1Password signin ==="
if ! op whoami >/dev/null 2>&1; then
  err "1Password CLI not signed in."
  if [ "$PLATFORM" = mac ]; then
    err "  Open 1Password app → Settings → Developer → 'Integrate with 1Password CLI', then re-run."
  else
    err "  Run interactively:"
    err "    op account add"
    err "    eval \$(op signin)"
    err "  Then re-run this script."
  fi
  exit 1
fi
ok "1Password CLI signed in: $(op whoami | head -1 | tr -s ' ')"

# =============================================================================
# Tier 3: install Claude Code + Vercel CLI
# =============================================================================
log "=== Tier 3: install Claude Code + Vercel CLI ==="

if ! have claude; then
  log "npm install -g @anthropic-ai/claude-code"
  $SUDO npm install -g @anthropic-ai/claude-code
fi
ok "claude: $(claude --version 2>&1 | head -1)"

if ! have vercel; then
  log "npm install -g vercel"
  $SUDO npm install -g vercel
fi
ok "vercel: $(vercel --version 2>&1 | head -1)"

# =============================================================================
# Configure 1P MCP plugin in ~/.claude.json
# =============================================================================
log "=== Configuring 1Password MCP plugin in $CLAUDE_JSON ==="
SA_TOKEN=$(op read "$SA_TOKEN_REF" 2>/dev/null) || {
  err "Could not read SA token from: $SA_TOKEN_REF"
  err "Override path with: SA_TOKEN_REF='op://Vault/Item/field' bash setup.sh"
  exit 1
}
[ -n "$SA_TOKEN" ] || { err "SA token came back empty"; exit 1; }

mkdir -p "$(dirname "$CLAUDE_JSON")"
TMP=$(mktemp)
if [ -f "$CLAUDE_JSON" ]; then
  jq --arg t "$SA_TOKEN" '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers["1password"] = {
      command: "npx",
      args: ["-y", "@takescake/1password-mcp"],
      env: { OP_SERVICE_ACCOUNT_TOKEN: $t }
    }
  ' "$CLAUDE_JSON" > "$TMP"
else
  jq -n --arg t "$SA_TOKEN" '
    {
      mcpServers: {
        "1password": {
          command: "npx",
          args: ["-y", "@takescake/1password-mcp"],
          env: { OP_SERVICE_ACCOUNT_TOKEN: $t }
        }
      }
    }
  ' > "$TMP"
fi
jq empty "$TMP" >/dev/null
mv "$TMP" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON"
ok "Wrote $CLAUDE_JSON (mode 600)"

# =============================================================================
# Tier 4: enable plugins + Remote Control in ~/.claude/settings.json
# =============================================================================
log "=== Tier 4: enable Claude Code plugins + Remote Control ==="
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
chmod 700 "$(dirname "$CLAUDE_SETTINGS")"

PLUGINS_JSON='{
  "frontend-design@claude-plugins-official": true,
  "superpowers@claude-plugins-official": true,
  "code-review@claude-plugins-official": true,
  "playwright@claude-plugins-official": true,
  "github@claude-plugins-official": true,
  "skill-creator@claude-plugins-official": true,
  "claude-md-management@claude-plugins-official": true,
  "feature-dev@claude-plugins-official": true,
  "claude-code-setup@claude-plugins-official": true,
  "vercel@claude-plugins-official": true
}'

TMP=$(mktemp)
if [ -f "$CLAUDE_SETTINGS" ]; then
  jq --argjson p "$PLUGINS_JSON" '
    .enabledPlugins = ((.enabledPlugins // {}) + $p) |
    .remoteControl = ((.remoteControl // {}) + {enabled: true})
  ' "$CLAUDE_SETTINGS" > "$TMP"
else
  jq -n --argjson p "$PLUGINS_JSON" '{ enabledPlugins: $p, remoteControl: { enabled: true } }' > "$TMP"
fi
jq empty "$TMP" >/dev/null
mv "$TMP" "$CLAUDE_SETTINGS"
chmod 600 "$CLAUDE_SETTINGS"
ok "Wrote $CLAUDE_SETTINGS (mode 600)"

# =============================================================================
# gh CLI auth via 1P PAT (best-effort)
# =============================================================================
log "=== GitHub CLI auth ==="
if gh auth status >/dev/null 2>&1; then
  ok "gh already authenticated as: $(gh api user --jq .login 2>/dev/null || echo unknown)"
else
  if GH_PAT=$(op read "$GH_PAT_REF" 2>/dev/null) && [ -n "$GH_PAT" ]; then
    if printf '%s' "$GH_PAT" | gh auth login --with-token >/dev/null 2>&1; then
      ok "gh authenticated via 1P PAT (from $GH_PAT_REF)"
    else
      warn "gh auth login --with-token failed; run 'gh auth login' manually"
    fi
  else
    warn "No GH PAT at $GH_PAT_REF — run 'gh auth login' manually"
  fi
fi

# =============================================================================
# Vercel CLI auth — set up env-var based on 1P (best-effort, doesn't modify shell rc)
# =============================================================================
log "=== Vercel CLI auth ==="
if vercel whoami >/dev/null 2>&1; then
  ok "vercel already authenticated as: $(vercel whoami 2>&1 | tail -1)"
else
  if VERCEL_TOKEN=$(op read "$VERCEL_TOKEN_REF" 2>/dev/null) && [ -n "$VERCEL_TOKEN" ]; then
    if VERCEL_TOKEN="$VERCEL_TOKEN" vercel whoami >/dev/null 2>&1; then
      ok "Vercel PAT in 1P validates. To use automatically, add to your shell rc:"
      echo "    export VERCEL_TOKEN=\$(op read '$VERCEL_TOKEN_REF' 2>/dev/null)"
    else
      warn "Vercel PAT in 1P didn't validate; run 'vercel login' manually"
    fi
  else
    warn "No Vercel PAT at $VERCEL_TOKEN_REF — run 'vercel login' manually"
  fi
fi

# =============================================================================
# Final summary
# =============================================================================
echo
ok "Setup complete."
echo
echo "Manual steps remaining (one-time per machine):"
echo "  1. claude login       — authenticate Claude Code to your Anthropic account"
echo "  2. claude             — start a session; verify mobile app sees it"
echo "  3. (Headless) tmux new -d -s claude 'claude --remote-control'   — persistent session"
echo
echo "Optional shell rc additions (only if you want auto-loaded env vars):"
echo "  export VERCEL_TOKEN=\$(op read '$VERCEL_TOKEN_REF' 2>/dev/null)"
