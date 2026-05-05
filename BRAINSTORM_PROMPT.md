# Brainstorm prompt — finish claude-setup + cross-machine memory

> Paste the body of this file (or just say "read BRAINSTORM_PROMPT.md and
> let's go") into a fresh Claude Code session started in this repo's
> root. The new session will not have prior conversation context, so the
> recap below is intentionally complete.

---

/superpowers:brainstorming

# Goal: One-command bootstrap of a portable, context-aware Claude Code environment

I want to finish what I started in this repo. The end state: on any new
machine (Mac or Linux), I run a single curl|bash one-liner, enter my
1Password master password once, and within a few minutes I have:

1. Claude Code installed and authenticated.
2. The 1Password MCP plugin wired up with my Service Account token, so
   any session can fetch my Stripe/OpenAI/GitHub/Vercel/Resend/etc.
   credentials at runtime — never persisted to disk, never in git.
3. `gh` CLI authenticated, so I can clone any of my repos.
4. Claude Code preconfigured with the plugins I rely on (1P, GitHub,
   Vercel, Playwright, etc.) and my keybindings.
5. **Cross-machine memory continuity** — when I start a session in a
   freshly-cloned repo on a new machine, Claude already knows the
   project's history, decisions, and ongoing TODOs the same way it does
   on my Mac. This is the missing piece today.
6. **Sensible CLAUDE.md defaults out of the box.**
   - A **global `~/.claude/CLAUDE.md`** dropped in by `setup.sh` so every
     session on every machine starts with my house rules (credentials
     live in 1P Development vault, fetch via the 1P MCP plugin, never
     commit secrets, prefer simplicity over architecture, etc.).
   - A **per-repo CLAUDE.md template** (`templates/CLAUDE.md` in this
     repo, or a `claude-init` helper) so starting a new project
     scaffolds a working agreement modeled on giftasong's
     "Working agreement for Claude" — bootstrap section, tooling
     references, project-specific rules.
   - Mechanism for keeping the global file in sync across machines (it's
     the same problem as memory sync, possibly the same solution).
7. On Linux servers (Hetzner): `claude remote-control` running in tmux
   under systemd with a watchdog, so the mobile app can attach when my
   laptop is asleep.

## What's already done — read these before brainstorming

- `README.md` — entry-point user guide.
- `ARCHITECTURE.md` — design doc, source of truth for cred + tooling
  layout. Includes the `WEBSITE_CONFIG_NAME=giftasong` pattern that apps
  inherit.
- `setup.sh` — 516-line idempotent installer. Tiers 2–5 implemented:
  prereqs, Claude Code + Vercel CLI, MCP plugin + plugin enablement,
  Linux `claude-rc.service` + watchdog timer.
- Recent commits (last 10 via `git log --oneline -10`) for context on
  what was fixed most recently.

## What's already decided — do NOT re-propose

- **No broker.** A Hetzner-hosted 1P credential broker was designed and
  scrapped on 2026-05-03 once Remote Control shipped. 1Password runs
  locally on every machine. Mobile/web is just a synchronized view of a
  local Claude session via Remote Control. No Cloudflare Tunnel, no
  Pushover, no custom MCP connector. Don't bring these back.
- **Public repo, secret-less code.** The one-liner has to be curlable
  without auth, so the repo stays public. All credentials are read from
  1Password at runtime, never committed.
- **One manual step is acceptable** per machine: entering my 1Password
  master password once to authenticate `op` CLI. Beyond that, fully
  automated.

## Known unfinished / unreliable today

- **Tier 1 fragility.** On a truly fresh Mac (no Homebrew) or fresh
  Linux, the script can fail if `brew`, `op`, `node`, or `jq` aren't
  pre-installed. Tier 2 needs to bootstrap those itself.
- **Touch ID friction.** Setup prompts Touch ID for the Mac user-session
  `op read` even though the resulting token is then stored as an SA
  token. The token-fetch step could be tighter.
- **Em-dash bug** in 1P item titles broke `op://` URI parsing —
  worked around with item-ID lookup, but the workaround is fragile if
  vault contents change.
- **Cross-machine memory:** completely unaddressed. Today, opening
  `claude` in `~/Documents/GitHub2/foo` on machine A and machine B gives
  you two empty `memory/` dirs that never converge.
- **End-to-end re-verification:** recent fixes haven't been tested in a
  real Mac → fresh-VM round-trip.

## Constraints I care about

- **Low-stake security, high-stake simplicity.** I'm not a target. I'd
  rather a 95%-secure setup I'll actually use over a 100%-secure one I
  abandon. That said: I build web apps. **Don't put plaintext memory in
  any git repo I might publish.** If memory goes in git, it must be
  encrypted (age / git-crypt / sops / similar) with the key in 1P.
- **Easy on new machines.** The whole pitch is "one curl|bash, one 1P
  unlock, then go." Anything that adds steps loses.
- **Works for any project, any device.** Mac, Hetzner, future machines.
  Repo-scoped or global memory both fine — pick whichever is simpler.

## What I want from this brainstorm

I'm specifically open about:

1. **Where memory lives.** Options I've already half-considered:
   - In each repo as `.claude-memory/` (encrypted with age, key in 1P).
   - Synced via Syncthing on `~/.claude/projects/`.
   - Centralized in a tiny KV (Cloudflare KV or 1P note keyed by repo
     remote URL).
   - A private mirror repo paired with each public repo.
   - Some combination.
2. **How "context resume" actually triggers** when I start a session
   on a new machine. SessionStart hook? Manual `/load-memory`? A wrapper
   that runs before `claude`?
3. **Whether `setup.sh` should also handle memory bootstrap**, or
   whether memory is a separate `claude-memory` tool. Single repo vs
   two.
4. **Encryption mechanics.** age vs git-crypt vs sops. Where the
   keypair lives (1P), how new machines get the decrypt key (during
   setup.sh), how rotation works.
5. **CLAUDE.md strategy.** What goes in the global
   `~/.claude/CLAUDE.md` vs the per-repo `CLAUDE.md`? How opinionated
   should the per-repo template be? Should `setup.sh` overwrite an
   existing global CLAUDE.md or merge? Is there a "sections" pattern
   (e.g. a managed block delimited by markers that setup.sh can update,
   leaving the rest of the file alone)?
6. **What's out of scope** so we don't gold-plate.

Walk me through the design space. Surface the tradeoffs I haven't
thought of. Push back if any of my assumptions are wrong. I want to
land on the simplest thing that works, not the most architecturally
satisfying one.

## After brainstorm

Once we've narrowed direction, we'll switch to `superpowers:writing-plans`
to produce a plan file, then `superpowers:executing-plans` to implement
in stages. TDD applies to setup.sh assertions
(`superpowers:test-driven-development`). Verification before completion
is mandatory — "I never got it to work reliably" is the failure mode
we're trying to prevent.

The first deliverable in implementation should be a memory file in the
new session's `memory/` dir capturing the chosen direction — testing
the very mechanism we're building.
