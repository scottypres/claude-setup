#!/usr/bin/env bash
# Claude Code + 1Password setup for any of Scott's computers.
# One prerequisite: be signed into 1Password (CLI integration on Mac, or `op signin` on Linux).
# Idempotent — safe to re-run.

set -euo pipefail

# --- helpers ---
c_blue=$'\033[1;34m'; c_red=$'\033[1;31m'; c_yellow=$'\033[1;33m'; c_green=$'\033[1;32m'; c_off=$'\033[0m'
log()  { printf '%s[%s]%s %s\n'  "$c_blue"   "$(date +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$c_yellow" "$(date +%H:%M:%S)" "$c_off" "$*"; }
err()  { printf '%s[%s] ERR%s  %s\n' "$c_red"    "$(date +%H:%M:%S)" "$c_off" "$*" >&2; }
ok()   { printf '%s[%s] OK%s   %s\n' "$c_green"  "$(date +%H:%M:%S)" "$c_off" "$*"; }

# --- config (override via env vars) ---
SA_TOKEN_REF="${SA_TOKEN_REF:-op://Development/1Password — Service Account Token/password}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"

# --- platform detection ---
case "${OSTYPE:-}" in
  darwin*)  PLATFORM=mac ;;
  linux*)   PLATFORM=linux ;;
  *)        err "Unsupported platform: ${OSTYPE:-unknown}"; exit 1 ;;
esac
log "Platform: $PLATFORM"

# --- prereq check ---
need() {
  local cmd=$1 hint=$2
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required tool: $cmd"
    err "Install: $hint"
    exit 1
  fi
}

need git "your distro's package manager (Mac: bundled with Xcode CLT)"
need jq "$( [ "$PLATFORM" = mac ] && echo 'brew install jq' || echo 'apt install jq' )"
need op "$(  [ "$PLATFORM" = mac ] && echo 'brew install --cask 1password-cli' || echo 'see https://developer.1password.com/docs/cli/get-started/' )"
need node "$([ "$PLATFORM" = mac ] && echo 'brew install node' || echo 'see https://nodejs.org/ or use nvm' )"
need npm "comes with node"
ok "All prereq tools present"

# --- 1Password signin check ---
if ! op whoami >/dev/null 2>&1; then
  err "1Password CLI is not signed in."
  if [ "$PLATFORM" = mac ]; then
    err "  Either: open the 1Password desktop app and enable CLI integration"
    err "          (1Password → Settings → Developer → Integrate with 1Password CLI)"
    err "  Or:     run 'op signin' interactively"
  else
    err "  Run: op account add   (then 'op signin')"
    err "  See: https://developer.1password.com/docs/cli/sign-in-manually/"
  fi
  exit 1
fi
ok "1Password CLI signed in as: $(op whoami | head -1)"

# --- install Claude Code ---
if ! command -v claude >/dev/null 2>&1; then
  log "Installing Claude Code via npm..."
  npm install -g @anthropic-ai/claude-code
  ok "Installed Claude Code: $(claude --version 2>&1 | head -1)"
else
  ok "Claude Code already installed: $(claude --version 2>&1 | head -1)"
fi

# --- fetch SA token from 1P ---
log "Fetching 1P service-account token from: $SA_TOKEN_REF"
SA_TOKEN=$(op read "$SA_TOKEN_REF" 2>/dev/null) || {
  err "Could not read SA token from 1P at: $SA_TOKEN_REF"
  err "Either:"
  err "  - Ensure that 1P item exists in the Development vault, or"
  err "  - Override the path: SA_TOKEN_REF='op://Vault/Item/field' ./setup.sh"
  exit 1
}
[ -n "$SA_TOKEN" ] || { err "SA token came back empty"; exit 1; }
ok "SA token retrieved"

# --- merge 1P MCP server config into ~/.claude.json ---
log "Configuring 1Password MCP plugin in $CLAUDE_JSON"
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
# Verify result is valid JSON before swapping
jq empty "$TMP" >/dev/null
mv "$TMP" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON"
ok "Wrote $CLAUDE_JSON (mode 600)"

# --- Remote Control setting (writes to user settings, separate file) ---
SETTINGS_DIR="$HOME/.claude"
SETTINGS_JSON="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"
chmod 700 "$SETTINGS_DIR"
TMP=$(mktemp)
if [ -f "$SETTINGS_JSON" ]; then
  jq '.remoteControl = (.remoteControl // {}) | .remoteControl.enabled = true' "$SETTINGS_JSON" > "$TMP"
else
  jq -n '{ remoteControl: { enabled: true } }' > "$TMP"
fi
jq empty "$TMP" >/dev/null
mv "$TMP" "$SETTINGS_JSON"
chmod 600 "$SETTINGS_JSON"
ok "Enabled Remote Control by default in $SETTINGS_JSON"
warn "If Claude Code uses a different config path/key for Remote Control,"
warn "  run /config inside Claude Code and toggle 'Enable Remote Control for all sessions'."

# --- final notes ---
echo
ok "Setup complete."
echo
echo "Next steps (interactive — script can't do these):"
echo "  1. If Claude Code is not yet authenticated to your Anthropic account,"
echo "     run:  claude login   (or export ANTHROPIC_API_KEY)"
echo "  2. Start a session:  claude"
echo "  3. From your phone (Anthropic mobile app), this local session should appear."
echo "  4. Test 1P MCP: in the session, ask 'list items in my Development vault'."
echo
echo "On Hetzner / headless: also run a persistent session in tmux so Remote Control survives logout:"
echo "  tmux new -d -s claude 'claude --remote-control'"
