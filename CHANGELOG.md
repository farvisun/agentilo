# Changelog

All notable changes to Agentilo are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). The release workflow publishes each version's section as its GitHub release notes, which Sparkle shows when it offers the update.

## [Unreleased]

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

[Unreleased]: https://github.com/farvisun/agentilo/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/farvisun/agentilo/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/farvisun/agentilo/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/farvisun/agentilo/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/farvisun/agentilo/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/farvisun/agentilo/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/farvisun/agentilo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/farvisun/agentilo/releases/tag/v0.1.0
