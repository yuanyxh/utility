# Agent Health

## 2026-11-08

- Baseline created by the 1.5.0 upgrade; no steward run yet.
- Next check: 2026-11-15.
- Maintenance mode: hook.
- Scope checked: prompts, rules, skills, memory, hooks, MCP, subagents, commands, plugins, environment.

## 2026-11-20

- First full steward run; report age at start 12 days (threshold 7).
- Snapshot: macOS 27.2.1, Swift 6.4.2, master dirty (`VERSION`, `.agent/sandbox.md`).
- Applied: memory INDEX corrections (seed 1.5.0, `.agent-gateway/graph.sqlite`, notice removal), backlog todo-001 archived, AGENTS skill index adds sandbox/steward, environment re-probed.
- Open findings: `yunxiao` MCP Authorization is a literal token in `~/.claude.json` (user chose not to change); `status.md` six stale in-progress bullets archived same day (todo-20261120-001).
- Passing: budgets 118/200, core 13/60, rules <=113/120; hook registered and executable; 7 unique skills; all verification entrypoints resolve; no secrets in repo assets.
- Next check: 2026-11-27.
