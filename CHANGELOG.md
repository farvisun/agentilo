# Changelog

All notable changes to Agentilo are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). The release workflow publishes each version's section as its GitHub release notes, which Sparkle shows when it offers the update.

## [Unreleased]

### Added

- A global shortcut opens and closes the notch from anywhere (Settings → General, none by default). Opened this way it stays open until the shortcut, Esc or a click outside.
- Hide while the screen is shared or recorded (Settings → General, off by default): the notch steps aside and holds alerts, as for a full-screen app.
- Copy an image of an account's limits from its page in the notch. It leaves out the email and account name.

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

[Unreleased]: https://github.com/farvisun/agentilo/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/farvisun/agentilo/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/farvisun/agentilo/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/farvisun/agentilo/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/farvisun/agentilo/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/farvisun/agentilo/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/farvisun/agentilo/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/farvisun/agentilo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/farvisun/agentilo/releases/tag/v0.1.0
