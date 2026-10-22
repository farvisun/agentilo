# Agent Limits

Notch app for macOS 14+ that shows Claude Code, Codex and Cursor plan limits beside the MacBook notch, plus local token statistics.

- **Collapsed**: ring + percentage of the most critical account, colored by pace.
- **Hover**: notch expands with session/weekly meters, reset times, pace ("On track", "Ahead of pace", "Runs out 7:24 PM"), live session row. Scroll or use arrows to page through accounts and the token stats page.
- **Alerts**: drop down out of the notch at 75%, 90% and 100% of a window (with the projected run-out time) and when a window resets. Optional sound. Settings → Alerts.
- **Local API + CLI**: `GET http://127.0.0.1:6737/v1/limits` (loopback only, refuses browser pages, no credentials) and `agentlimits limits [--json|--short] [--force]` for scripts and status lines; falls back to cached numbers when the app is not running. Install the command in Settings → Agents.
- **Agents**: live list of running agents (working, waiting for approval or input, done) with the current tool and task, from [herdr](https://herdr.dev) and/or Claude Code / Codex hooks. A pulsing dot on the pill and a drop-down alert when an agent needs you or finishes a longer turn; click a row to jump to its herdr pane in Ghostty. Install hooks per home in Settings → Agents (commands marked `# agentlimits`, other hooks untouched, original kept as `*.agentlimits-bak`).
- **Accounts**: every agent home is its own account (`~/.claude`, `~/.claude_multi/*`, `~/.codex*`, Cursor). Auto-detected on first launch; edit in Settings → Accounts.
- **Proxy**: global System / None / HTTP / HTTPS / SOCKS5 with optional auth (password in Keychain), plus per-provider override and a connection test.

## Build

```sh
make run        # build release, bundle build/AgentLimits.app, ad-hoc sign, launch
make install    # copy to /Applications
make test       # unit tests
make dump       # print every account's limits and token stats in the terminal
```

## Data sources (read-only)

| Provider | Credential | Endpoint |
|---|---|---|
| Claude | Keychain `Claude Code-credentials[-<sha256(home)[:8]>]` or `<home>/.credentials.json` | `GET api.anthropic.com/api/oauth/usage` |
| Codex | `<home>/auth.json` | `GET chatgpt.com/backend-api/wham/usage` |
| Cursor | `state.vscdb` → `cursorAuth/accessToken` | `GET cursor.com/api/usage-summary` |

Tokens are never refreshed or rewritten and are only sent to their own provider. These endpoints are undocumented and may change.

### When the API is unavailable

If a provider rate limits the app, is unreachable, or the sign-in expired, the notch falls back to disk:

- **Codex**: every `token_count` event in `<home>/sessions/**/*.jsonl` carries `rate_limits` (used %, window, reset), so limits are exact as of the last Codex turn. Shown as "from Codex logs".
- **Claude**: Claude Code stores no limit percentages on disk. Each successful fetch records "% per cost-weighted token" for each window from the local logs; offline, the last response is advanced by tokens logged since, shown as "≈ estimated". Usage from other machines or claude.ai is not seen locally.
- Windows past their reset roll over to 0%. `make dump ARGS=--offline` prints the fallback without calling any server.

Token statistics come from `<home>/projects/**/*.jsonl` (Claude) and `<home>/sessions/**/*.jsonl` (Codex), deduplicated across files by message id, cached incrementally in `~/Library/Application Support/AgentLimits/`.
