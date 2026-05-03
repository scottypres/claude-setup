# Architecture — Credentials, Tools, Compute

Single source of truth for how my development environment is wired across machines and services. If you're on a fresh machine, run `setup.sh` (see [README.md](README.md)). This doc explains *why* the script does what it does.

## Source of truth

**1Password SaaS (`my.1password.com`)** is the canonical store for every credential. Nothing else is the source of truth — Vercel env vars, Baserow rows, shell rc files all hold *copies or env-references* sourced from 1P.

## Vault structure

A single working vault: **`Development`**. Everything goes here — control-plane creds for me, runtime creds for apps, deploy tokens, API keys, generated SSH keys, OAuth tokens.

**Tradeoff acknowledged.** A single vault means anything with read access to `Development` (e.g., a leaked `OP_SERVICE_ACCOUNT_TOKEN` from a Vercel env var, the broker daemon if one is ever stood up, a compromised laptop) can read *every* credential. That's accepted risk in exchange for management simplicity. Mitigations: tight rotation cadence on tokens, no high-stakes prod data exists yet, use `Personal` (separate vault) only if/when something genuinely warrants additional isolation.

The personal vault stays untouched by service accounts.

## Compute environments

Three places where I run Claude Code:

| Environment | Auth to 1P | Auth to Anthropic | Always-on? |
|---|---|---|---|
| **Mac** (`Scotts-MacBook-Pro`) | 1P desktop app + CLI integration (Touch ID for `op` user-session calls); 1P MCP plugin uses SA token in `~/.claude.json` for Claude Code | macOS Keychain (`Claude Code-credentials`) | No — sleeps when laptop closes |
| **Hetzner** (`178.156.231.202`, Ubuntu 24.04) | SA token in `/etc/claude-runner.env` (root-owned, 0600), loaded by systemd `EnvironmentFile=` and root's `.bashrc` | `/root/.claude/.credentials.json` (full-scope subscription token from `claude auth login --claudeai`) | Yes — `claude-rc.service` always running in tmux |
| **Any other computer** | Same as Mac path: 1P CLI integration → Touch ID; SA token written to local `~/.claude.json` by `setup.sh` | `claude auth login --claudeai` once per machine | Same as Mac |

Mac is the primary; Hetzner is the always-on backup brain reachable from the Anthropic mobile app via Remote Control when the laptop is asleep.

## Remote Control

Anthropic's [Remote Control](https://code.claude.com/docs/en/remote-control) feature (shipped Feb 2026) lets the Claude mobile app and `claude.ai/code` *attach* to a Claude Code session running on my own hardware. The session's tools (1P MCP plugin, filesystem, shell, MCP servers) all stay local; the mobile app is just a synchronized view.

**This replaced the "broker MCP server" architecture I'd been designing.** A broker would have stored a bearer token on Anthropic infrastructure and proxied credential requests over HTTPS — strictly worse for the "no creds on Anthropic" goal than Remote Control's "no remote MCP at all" design.

Mobile/cloud Claude is therefore *credential-less by design*. To do credentialed work from a phone: open the mobile app, attach to the Hetzner (or Mac) Remote Control session, and the local Claude there handles tool calls including 1P reads. Credentials never need to leave the local machine.

## Where each kind of thing lives

| Kind of data | Lives in | Read by |
|---|---|---|
| **Credentials** (API keys, tokens, secrets, passwords, OAuth refresh tokens, signing keys, deploy hooks containing tokens) | 1Password `Development` vault | Local Claude Code via 1P MCP plugin; web apps via runtime fetch with an `OP_SERVICE_ACCOUNT_TOKEN` |
| **Reference data** (project IDs, public URLs, table IDs, model names, account usernames, folder IDs, non-secret config) | Baserow (per-project config rows in tables like `website_config`) | Web apps at runtime; setup scripts |
| **Vercel env vars** | Vercel project env (encrypted at rest) | Web app at runtime — but only the *bootstrap-minimum* (see below) |
| **Build-time public vars** (`NEXT_PUBLIC_*`, `VITE_*` ) | Vercel env (must be there at build time, ship to client JS) | The build process; eventually inlined into client bundles |

## Vercel bootstrap-minimum

Each Vercel project should have **only these env vars**:

1. **One fetcher credential** — either `OP_SERVICE_ACCOUNT_TOKEN` (1P route) or `BASEROW_TOKEN` (Baserow route).
2. **The endpoint** the app calls — `BASEROW_URL` for the Baserow route, implicit for 1P.
3. **An identifier** so the app knows *which* config is its — e.g., `WEBSITE_CONFIG_NAME=giftasong`.
4. **Build-time public vars** that ship in client bundles.

Everything else lives in 1P (secrets) or Baserow (config) and is fetched at runtime / startup. Net per project: **2–4 env vars** instead of the 14+ some currently have.

## Token lifecycle

| Token | Stored | Rotated when |
|---|---|---|
| `hetzner-runner` 1P SA token | `/etc/claude-runner.env` on Hetzner; copy in 1P `Development` | 90 days, or on suspected compromise |
| Mac 1P SA token | `~/.claude.json` (mode 0600) under `mcpServers["1password"].env`; copy in 1P | Same — 90 days, or on suspected compromise |
| Web-app 1P SA tokens (one per Vercel project once migration completes) | Vercel project env; copy in 1P | 90 days |
| Claude.ai full-scope subscription token (Hetzner) | `/root/.claude/.credentials.json`, generated by `claude auth login --claudeai` | Rare — typically only on suspected compromise; it's tied to your claude.ai account |
| Claude.ai inference-only OAuth token (`setup-token`) | Generated when needed for headless `claude --print` work; stored in 1P | Rare |
| GitHub PAT | 1P `Development`; injected into Hetzner env via `setup.sh`, into Mac env via shell rc line | 90 days |
| Vercel PAT | 1P `Development`; injected via `setup.sh` | 90 days |
| Cloudflare API token | 1P `Development` | 90 days |
| Hetzner Cloud API token | 1P `Development` | 90 days |
| Hetzner SSH private key | 1P `Development` (used via 1P SSH agent on Mac) | Annual |

## Day-to-day flows

### Local Claude Code on Mac needs a credential
Claude Code → 1P MCP plugin → reads SA token from process env (loaded from `~/.claude.json` `mcpServers` config) → calls 1P API → returns item. **No Touch ID** (SA token, not user session). Personal vault not accessible to this path; Development vault is.

### I'm on my phone, Mac is asleep
Open Anthropic mobile app → attach to Hetzner Remote Control session (named via `--remote-control-session-name-prefix` or set inside the live UI) → type prompt → Hetzner Claude executes tools locally, including 1P reads via the on-Hetzner MCP plugin → response synced back to phone. **Credentials stay on Hetzner.**

### Web app on Vercel needs to handle a request
Cold start → reads `BASEROW_TOKEN` + `BASEROW_URL` from process env (the bootstrap minimum) → fetches its config row from Baserow → resolves table IDs and non-secret config → reads its `OP_SERVICE_ACCOUNT_TOKEN` (also bootstrap, if going 1P route) → fetches secrets from 1P `Development` → handles request.

### A new credential needs to exist
Generate at the source service (Stripe dashboard, Vercel, etc.) → create item in 1P `Development` → add a reference row in Baserow if the app needs to know about it → if app already has `OP_SERVICE_ACCOUNT_TOKEN`, redeploy and it'll fetch the new item by name; otherwise add to Vercel env once.

## Where this doc lives, and why it's public

This repo (`claude-setup`) is public. The script and this doc contain **no secrets** — all sensitive values are pulled from 1P at runtime by reference. Making it public lets `setup.sh` be installed via a `curl | bash` one-liner without GitHub auth, on any machine, anywhere.

The `Development` vault contents and the actual credential values are entirely in 1P, gated by my master password + secret key + 2FA.
