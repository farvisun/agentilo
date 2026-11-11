# Changelog

All notable changes to Agentilo are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). The release workflow publishes each version's section as its GitHub release notes, which Sparkle shows when it offers the update.

## [Unreleased]

## [0.9.0] - 2026-11-11

### Added

- Burning fast alert: when the pace runs a window out before its reset while usage is still below every threshold. Once per window, again only after the pace is back on track. Settings → Alerts, on by default.
- Use it or lose it alert: a window longer than a day that resets within 24 hours with more than half left. Settings → Alerts, on by default.
- Codex Spark session and weekly limits, the credit balance (with its approximate dollar value) and a workspace credit limit when one is set.
- Cursor shows the plan's split between Cursor's own models and other models, and the team's on-demand spend when the limit is the team's.
- Copilot on GitHub Enterprise Cloud (GHE.com), Copilot Free quotas, and extra premium requests when the plan allows them.
- OpenCode Go session, weekly and monthly limits, read with the key the OpenCode CLI keeps in `~/.local/share/opencode/auth.json`. Detected automatically.
- Several Claude or Codex accounts can share one page in the notch, each limit averaged over the accounts; hover a limit for each account (Settings → Accounts).
- While the screen is shared or recorded, Agentilo can blur account names and emails instead of hiding the notch (Settings → General).
- Right-click a provider's icon in the notch for its status page and usage dashboard.
- Click the "updated" time on an account page to check now; its tooltip shows when the next check is due.
- `agentilo limits <provider|label|id>` shows one account; `/v1/limits` and `--json` add `expiresAt` and `stale` per account.
- Limits past the third and balances are listed on one line under the meters, so Claude's model limits and extra usage are no longer cut off.

### Changed

- A provider's `Retry-After` is honoured, also by a manual refresh, and survives a relaunch; Claude homes signed in to the same login share it. GitHub's 403 rate limit counts as one. Backoff now grows up to an hour.
- A refresh that takes longer than 120 seconds is given up and retried later.

## [0.8.1] - 2026-11-11

### Added

- Agents are found in any terminal without herdr or hooks: Agentilo reads running Claude Code, Codex and Gemini CLI processes and their transcripts to show working and finished sessions (Settings → Agents → Detect agents from running processes, on by default). Hooks still add the current tool, approvals and questions.
- On first launch after the update, Agentilo offers once to install hooks in homes that lack them. Settings → Agents → Hooks has an Install all button.

### Fixed

- Clicking an agent outside herdr brings forward the app it runs in (Ghostty, Otty, iTerm2, Terminal, VS Code, Cursor, …) instead of always Ghostty.
- Installing hooks in a home whose `settings.json` or `hooks.json` is a symlink edits the linked file instead of replacing the link with a copy. Homes sharing one file show it in Settings.
- A Codex session whose process exited no longer stays in the agent list for 30 minutes.

## [0.8.0] - 2026-11-04

### Added

- A global shortcut opens and closes the notch from anywhere (Settings → General, none by default). Opened this way it stays open until the shortcut, Esc or a click outside.
- Hide while the screen is shared or recorded (Settings → General, off by default): the notch steps aside and holds alerts, as for a full-screen app.
- Copy an image of an account's limits from its page in the notch. It leaves out the email and account name.
- GitHub Copilot limits, from your GitHub CLI login. Added by hand in Settings → Accounts, never auto-detected.
- OpenRouter credits and key limit, with a key you paste into Settings → Accounts, kept in the Keychain.
- Codex accounts show how many limit resets are available and when the next one expires, in the notch, `/v1/limits` and `agentilo limits --json`. Read only; Agentilo never spends one.

### Fixed

- Codex subagent and forked sessions no longer count the parent's history they replay at the start of their log, in tokens, cost, prompts and tool calls. Replayed limits no longer replace newer ones in the offline fallback.
- Cost estimates: one-hour Claude cache writes are priced at 2x input instead of 1.25x, fast mode at twice the rate, and Haiku 5.5 prompts over 100,000 tokens at the higher rate. Sonnet 5.5 cache hits are $0.10. `gpt-6.1-terra`, `gpt-6-luna`, `gpt-6-sol`, `gpt-5.3-codex` and Claude Mythos 5 now have prices. The last 30 days are recalculated on first launch; older days stay as recorded.
- A home whose log folder is a symlink to another home's now shows its token statistics, counted once when both are enabled.

## [0.7.0] - 2026-11-04

### Added

- The collapsed notch can rotate through every tracked account: choose "All accounts, rotating" in Settings → General, then the animation (horizontal slide, vertical slide, fade, scale and fade), how long each account shows and the animation speed. In click-to-expand mode a two-finger swipe over the notch moves it by hand.

### Fixed

- "Finished" alerts now appear while the terminal is in the background. herdr reports such a turn as `done`, which Agentilo ignored until the pane was seen, so the session also stayed "working" and kept the Mac awake.

## [0.6.1] - 2026-10-30

### Added

- `agentilo limits --short` ends in `· awake` (or `· awake (lid)`) while Keep awake holds the Mac awake, so a status line shows it. `--json` and `/v1/limits` carry the same state as `keepAwake`.
- This changelog; release notes now come from it.

### Changed

- Dependabot keeps Sparkle and the GitHub Actions up to date.

## [0.6.0] - 2026-10-30

### Added

- Keep awake: while an agent is working the Mac doesn't idle-sleep, on battery too, and the screen still locks. An optional root helper keeps it awake with the lid closed. Settings → Agents, the cup in the expanded notch, or `agentilo awake on|off|lid on|lid off|status`.

## [0.5.0] - 2026-10-28

### Added

- Gemini CLI: quota, session stats and hooks.

## [0.4.0] - 2026-10-28

### Added

- Suggest another account of the same agent when one runs low, with the command to switch.
- Reports: a notch page, a Monday summary of last week, and a Reports window with daily cost or tokens by project, model or agent.
- Codex usage is priced, and per-day breakdowns are kept for reports.

## [0.3.0] - 2026-10-28

### Added

- Quiet hours, snooze from the notch and `agentilo quiet`.
- The start of the agent's last reply and the turn's progress in the notch.

### Fixed

- The Homebrew cask uses `postflight_steps`, as current Homebrew requires.

## [0.2.0] - 2026-10-28

### Added

- Updates in place with Sparkle, and installation with Homebrew.

## [0.1.0] - 2026-10-28

### Added

- The first release: Claude Code, Codex and Cursor plan limits beside the notch, paced, with alerts, live agent sessions from herdr and hooks, permission prompts answered from the notch, an activity page, a loopback API and the `agentilo` command.

[Unreleased]: https://github.com/farvisun/agentilo/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/farvisun/agentilo/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/farvisun/agentilo/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/farvisun/agentilo/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/farvisun/agentilo/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/farvisun/agentilo/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/farvisun/agentilo/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/farvisun/agentilo/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/farvisun/agentilo/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/farvisun/agentilo/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/farvisun/agentilo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/farvisun/agentilo/releases/tag/v0.1.0
