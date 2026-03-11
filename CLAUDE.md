# AI Content Curator & Publisher

## Project Overview
Stateless pipeline: read Telegram channels → LLM curates digest → publish to Telegram, Ghost, and Substack.

## Architecture
- `agent/integrations/telegram/telegram.py` — Telegram I/O (read channels, publish digest)
- `agent/integrations/ghost/ghost.py` — Ghost publisher (main blog platform, Lexical format)
- `agent/integrations/substack/substack.py` — Substack publisher (secondary)
- `agent/integrations/substack/api.py` — Substack API client (vendored from python-substack)
- `.github/prompts/generate-digest-messenger.md` — Telegram prompt (short, emoji, links)
- `.github/prompts/generate-digest-blog.md` — Blog prompt (long-form HTML newsletter, used by Ghost and Substack)
- `.github/workflows/generate-digest.yml` — CI pipeline (daily cron)

## Pipeline
```
1. Collect    telegram.py --read --since 24        → /tmp/telegram_messages.json
2a. LLM      generate-digest-messenger.md             → /tmp/telegram_digest.txt (plain text)
2b. LLM      generate-digest-blog.md             → /tmp/blog_digest.txt (HTML)
3a. Publish   telegram.py --post                   → Telegram channel
3b. Publish   ghost.py --post                      → Ghost blog (main)
3c. Publish   substack.py --post                   → Substack newsletter (secondary)
```
Steps 2a/2b run in parallel. Steps 3a/3b/3c run in parallel.

## Publishing Platforms
- **Ghost** (aicmo.blog) — main blog, Admin API with JWT auth, content in Lexical JSON format
- **Telegram** — messenger digest (short, emoji, links)
- **Substack** — secondary blog, unofficial API with cookie auth

## LLM Auth
- Primary: `CLAUDE_CODE_OAUTH_TOKEN` via claude-code-action
- Fallback: `ANTHROPIC_API_KEY` (or any provider) via API
- Provider/model configurable via `LLM_PROVIDER`, `LLM_MODEL` repo variables

## Environment Variables
- `TELEGRAM_API_ID` — from my.telegram.org
- `TELEGRAM_API_HASH` — from my.telegram.org
- `TELEGRAM_SESSION_STRING` — from setup_session.py
- `TELEGRAM_PUBLISH_CHANNEL` — target channel (e.g. `@my_channel`)
- `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code OAuth token (primary)
- `ANTHROPIC_API_KEY` — Claude API key (fallback)
- `GHOST_URL` — Ghost domain without https:// (e.g. `aicmo.blog`)
- `GHOST_ADMIN_API_KEY` — Ghost Admin API key (format: `{id}:{secret}`)

- `SUBSTACK_COOKIE` — connect.sid cookie from browser (see substack/README.md)
- `SUBSTACK_PUBLICATION_URL` — e.g. `https://howai.substack.com`

## Agent Guidelines
- Fix content quality issues in `.github/prompts/`, not in scripts
- Pipeline is stateless — no persistent state, everything flows through /tmp/
- Respect Telegram rate limits — delays are built into telegram.py
- Ghost uses Lexical JSON format — never send raw HTML to Ghost API, convert to Lexical first
- Blog prompt outputs HTML — each publisher converts to its native format
- Substack uses an unofficial API — if it breaks, check python-substack upstream