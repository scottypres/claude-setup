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
# References use item TITLES which contain em-dashes. op CLI rejects em-dashes
# in op:// references (commit https://github.com/1Password/op-cli/...), so the
# script looks up items by title via `op item list` and uses the resolved IDs.
SA_TOKEN_TITLE="${SA_TOKEN_TITLE:-1Password — Service Account Token}"
GH_PAT_TITLE="${GH_PAT_TITLE:-GitHub — Personal Access Token}"
VERCEL_TOKEN_TITLE="${VERCEL_TOKEN_TITLE:-Vercel — Personal Access Token}"
ANTHROPIC_KEY_TITLE="${ANTHROPIC_KEY_TITLE:-Anthropic — API Key}"
OP_VAULT="${OP_VAULT:-Development}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# --- platform detect ---
case "${OSTYPE:-}" in
  darwin*)  PLATFORM=mac ;;
  linux*)   PLATFORM=linux ;;
  *)        err "Unsupported platform: ${OSTYPE:-unknown}"; exit 1 ;;
esac
log "Platform: $PLATFORM"

# --- on Linux, auto-load /etc/claude-runner.env if present (server bootstrap pattern) ---
RUNNER_ENV="${RUNNER_ENV:-/etc/claude-runner.env}"
if [ "$PLATFORM" = linux ] && [ -f "$RUNNER_ENV" ]; then
  log "Sourcing $RUNNER_ENV"
  set -a; . "$RUNNER_ENV"; set +a
fi

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
# Helper: resolve a 1P item title to its ID, then read a field
# =============================================================================
op_read_field() {
  # $1 = item title, $2 = field name (default: password)
  local title="$1" field="${2:-password}"
  local id
  id=$(op item list --vault "$OP_VAULT" --format=json 2>/dev/null \
        | jq -r --arg t "$title" '.[] | select(.title == $t) | .id' \
        | head -1)
  [ -n "$id" ] || return 1
  op read "op://$OP_VAULT/$id/$field" 2>/dev/null
}

# =============================================================================
# Configure 1P MCP plugin in ~/.claude.json
# =============================================================================
log "=== Configuring 1Password MCP plugin in $CLAUDE_JSON ==="
SA_TOKEN=$(op_read_field "$SA_TOKEN_TITLE") || {
  err "Could not read SA token item titled: $SA_TOKEN_TITLE (vault: $OP_VAULT)"
  err "Override with: SA_TOKEN_TITLE='Other Title' OP_VAULT='Other' bash setup.sh"
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
  if GH_PAT=$(op_read_field "$GH_PAT_TITLE") && [ -n "$GH_PAT" ]; then
    if printf '%s' "$GH_PAT" | gh auth login --with-token >/dev/null 2>&1; then
      ok "gh authenticated via 1P PAT (item: $GH_PAT_TITLE)"
    else
      warn "gh auth login --with-token failed; run 'gh auth login' manually"
    fi
  else
    warn "No 1P item titled '$GH_PAT_TITLE' in vault '$OP_VAULT' — run 'gh auth login' manually"
  fi
fi

# =============================================================================
# Vercel CLI auth — set up env-var based on 1P (best-effort)
# =============================================================================
log "=== Vercel CLI auth ==="
if vercel whoami >/dev/null 2>&1; then
  ok "vercel already authenticated as: $(vercel whoami 2>&1 | tail -1)"
else
  if VERCEL_TOKEN_VAL=$(op_read_field "$VERCEL_TOKEN_TITLE") && [ -n "$VERCEL_TOKEN_VAL" ]; then
    if VERCEL_TOKEN="$VERCEL_TOKEN_VAL" vercel whoami >/dev/null 2>&1; then
      ok "Vercel PAT in 1P validates. To auto-set in future shells:"
      echo "    Add to ~/.zshrc or ~/.bashrc:"
      echo "    export VERCEL_TOKEN=\$(op item get '$VERCEL_TOKEN_TITLE' --vault '$OP_VAULT' --fields password --reveal 2>/dev/null)"
    else
      warn "Vercel PAT in 1P didn't validate; run 'vercel login' manually"
    fi
  else
    warn "No 1P item titled '$VERCEL_TOKEN_TITLE' in vault '$OP_VAULT' — run 'vercel login' manually"
  fi
fi

# =============================================================================
# Anthropic API key — fetch from 1P, persist in /etc/claude-runner.env (Linux)
# =============================================================================
log "=== Anthropic API key ==="
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ok "ANTHROPIC_API_KEY already set in env"
else
  if KEY_VAL=$(op_read_field "$ANTHROPIC_KEY_TITLE" credential) && [ -n "$KEY_VAL" ]; then
    : "key found via 'credential' field"
  elif KEY_VAL=$(op_read_field "$ANTHROPIC_KEY_TITLE" password) && [ -n "$KEY_VAL" ]; then
    : "key found via 'password' field"
  fi
  if [ -n "${KEY_VAL:-}" ]; then
    if [ "$PLATFORM" = linux ]; then
      log "Persisting ANTHROPIC_API_KEY in $RUNNER_ENV"
      $SUDO sed -i '/^ANTHROPIC_API_KEY=/d' "$RUNNER_ENV" 2>/dev/null || true
      printf 'ANTHROPIC_API_KEY=%s\n' "$KEY_VAL" | $SUDO tee -a "$RUNNER_ENV" >/dev/null
      $SUDO chmod 600 "$RUNNER_ENV"
      export ANTHROPIC_API_KEY="$KEY_VAL"
      ok "ANTHROPIC_API_KEY persisted in $RUNNER_ENV (mode 600)"
    else
      ok "Anthropic key found in 1P. To use, add to your shell rc:"
      echo "    export ANTHROPIC_API_KEY=\$(op item get '$ANTHROPIC_KEY_TITLE' --vault '$OP_VAULT' --fields credential --reveal 2>/dev/null)"
    fi
    unset KEY_VAL
  else
    warn "No 1P item titled '$ANTHROPIC_KEY_TITLE' in vault '$OP_VAULT'"
    warn "Either: store an Anthropic API key in 1P with that title (field 'credential' or 'password'),"
    warn "        or run 'claude login' interactively after this script."
  fi
fi

# =============================================================================
# Linux only: install systemd service for always-running claude --remote-control
# =============================================================================
if [ "$PLATFORM" = linux ]; then
  log "=== Installing claude-rc systemd service (always-on Remote Control) ==="
  CLAUDE_BIN=$(command -v claude)
  TMUX_BIN=$(command -v tmux)
  log "claude binary: $CLAUDE_BIN"
  log "tmux binary:   $TMUX_BIN"

  $SUDO tee /etc/systemd/system/claude-rc.service >/dev/null <<UNIT
[Unit]
Description=Claude Code Remote Control session (in tmux)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=$RUNNER_ENV
ExecStart=$TMUX_BIN new-session -d -s claude-rc '$CLAUDE_BIN remote-control 2>&1 | tee -a /var/log/claude-rc.log'
ExecStop=$TMUX_BIN kill-session -t claude-rc
User=root

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable claude-rc.service >/dev/null 2>&1
  $SUDO systemctl restart claude-rc.service || warn "claude-rc.service failed to start; check 'journalctl -u claude-rc' and '/var/log/claude-rc.log'"
  if $SUDO systemctl is-active --quiet claude-rc.service; then
    ok "claude-rc.service is active and enabled (auto-starts on boot)"
  else
    warn "claude-rc.service installed but not active — likely needs Anthropic auth (claude login or ANTHROPIC_API_KEY)"
  fi

  # Also: a watchdog timer to restart the tmux session if claude exits inside it
  $SUDO tee /etc/systemd/system/claude-rc-watchdog.service >/dev/null <<UNIT
[Unit]
Description=Restart claude-rc.service if claude exited inside the tmux session
After=claude-rc.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$TMUX_BIN has-session -t claude-rc 2>/dev/null && $TMUX_BIN list-panes -t claude-rc -F "#{pane_dead}" | grep -q 1 && /bin/systemctl restart claude-rc.service || true'
UNIT
  $SUDO tee /etc/systemd/system/claude-rc-watchdog.timer >/dev/null <<UNIT
[Unit]
Description=Periodic check on claude-rc tmux session

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Unit=claude-rc-watchdog.service

[Install]
WantedBy=timers.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now claude-rc-watchdog.timer >/dev/null 2>&1
  ok "claude-rc-watchdog.timer enabled (checks every 2 min, restarts if claude died inside tmux)"
fi

# =============================================================================
# Final summary
# =============================================================================
echo
ok "Setup complete."
echo
if [ "$PLATFORM" = linux ]; then
  echo "Hetzner-style setup notes:"
  echo "  • /etc/claude-runner.env holds OP_SERVICE_ACCOUNT_TOKEN (and ANTHROPIC_API_KEY if found)."
  echo "  • claude-rc.service runs 'claude remote-control' in tmux; check with:"
  echo "      systemctl status claude-rc"
  echo "      tmux attach -t claude-rc      (Ctrl+b d to detach)"
  echo "      journalctl -u claude-rc -f"
  echo "      tail -f /var/log/claude-rc.log"
  echo "  • To restart: sudo systemctl restart claude-rc"
else
  echo "Mac next steps:"
  echo "  1. claude login                                  (one-time Anthropic OAuth in browser)"
  echo "  2. claude                                        (start a session)"
  echo "  3. /config inside Claude Code → enable Remote Control by default if not already"
  echo "  4. Anthropic mobile app → your local session should appear in the picker"
fi
