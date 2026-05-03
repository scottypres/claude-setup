# claude-setup

Single-script setup of Claude Code + 1Password MCP plugin on any of my machines (Mac or Linux). After this runs, Claude Code on the machine has access to my 1Password Development vault via the MCP plugin, and Remote Control is enabled so the session is reachable from the Anthropic mobile app.

## One-time prerequisite per machine: sign into 1Password

The only manual step the script can't automate is signing into 1Password (this is the "type my 1P password" exception). After that, everything else is fetched from 1P programmatically.

**On Mac:**

1. Install the 1Password desktop app from <https://1password.com/downloads/>.
2. Sign in (master password + secret key + 2FA, one time per OS install or when locked).
3. Enable CLI integration: 1Password → Settings → Developer → toggle "Integrate with 1Password CLI".
4. Verify in terminal: `op whoami` should print your user info.

**On Linux (e.g., Hetzner):**

1. Install the 1Password CLI: <https://developer.1password.com/docs/cli/get-started/>.
2. Add account: `op account add` (paste sign-in URL, email, secret key).
3. Sign in: `eval $(op signin)` (will prompt for master password). Repeat per session, or use a longer-lived session token.

## Run the setup

```sh
git clone git@github.com:scottypres/claude-setup.git ~/claude-setup
cd ~/claude-setup
./setup.sh
```

The script will:

- Detect Mac vs Linux.
- Verify required tools (`git`, `jq`, `op`, `node`, `npm`) are installed; tell you the install command if not.
- Verify 1Password CLI is signed in.
- Install Claude Code via npm if missing.
- Fetch the 1P service-account token from `op://Development/1Password — Service Account Token/password`.
- Write/merge the 1Password MCP plugin config into `~/.claude.json` (mode 0600).
- Enable Remote Control by default in `~/.claude/settings.json`.
- Print remaining interactive steps.

The script is **idempotent** — re-running won't break anything.

## After the script runs

Three things the script can't do for you:

1. **Authenticate Claude Code to your Anthropic account.** Run `claude login` once on the new machine, or set `ANTHROPIC_API_KEY` from a 1P-stored value.
2. **Start a session and verify the mobile app sees it.** Run `claude`, then check the Anthropic mobile app's session list.
3. **(Headless servers like Hetzner)** Start a persistent Remote Control session that survives SSH disconnect:
   ```sh
   tmux new -d -s claude 'claude --remote-control'
   ```
   To make it survive reboot, use a systemd user unit (not in this script — add later if needed).

## Configuring the SA token reference

By default the script reads from `op://Development/1Password — Service Account Token/password`. If your item is named differently, override per-run:

```sh
SA_TOKEN_REF='op://Development/Some Other Item/credential' ./setup.sh
```

## What's intentionally NOT in this repo

- No secrets. Nothing in this repo is sensitive — it's all just orchestration code that pulls secrets from 1Password at runtime.
- No machine-specific config. The script reads everything it needs from 1P at runtime so the same script works on every machine.

## Known limitations

- Remote Control config-file location/key may change as the feature evolves out of research preview. If `setup.sh`'s automatic toggle doesn't take effect, run `/config` inside Claude Code and toggle "Enable Remote Control for all sessions" manually.
- The script assumes the 1Password CLI is already signed in. It does not attempt to sign in for you (deliberately — the master-password prompt is the one manual step).
