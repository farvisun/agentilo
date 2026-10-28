# Security

Agentilo reads OAuth tokens that Claude Code, Codex and Cursor already store on your Mac, sends each one only to its own provider, and never refreshes or rewrites them. The local API listens on `127.0.0.1:6737` only, rejects requests from browser pages, and requires a per-install token for anything that changes state (agent events, approvals).

If you find a way around any of that, or anything else that puts credentials or approvals at risk, please report it privately through [GitHub security advisories](https://github.com/farvisun/agentilo/security/advisories/new) rather than in a public issue.
