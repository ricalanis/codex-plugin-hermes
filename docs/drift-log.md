# Drift Log — pull-reflect decisions

Record of upstream changes and how they were reflected (Port / Skip / Adapt). Maintained by the `pull-reflect` skill.

## 2026-07-19 — baseline

Initial port baseline. Upstream refs at time of port:
- `ref/codex-plugin-cc`: see `git -C ref/codex-plugin-cc rev-parse HEAD`
- `ref/hermes-agent`: see `git -C ref/hermes-agent rev-parse HEAD`

Standing **Skip** classes (Claude-Code-specific, never ported — justification in SPEC.md §0):
- app-server JSON-RPC broker (`app-server-broker.mjs`, `lib/broker-*`) → we use `codex exec`.
- `${CLAUDE_PLUGIN_ROOT}`, `$CLAUDE_PLUGIN_DATA`, `$CLAUDE_ENV_FILE` plumbing.
- `AskUserQuestion` / `Agent`-tool flows → deterministic companion logic + flags.
- `~/.claude/projects` transfer jail + `externalAgentConfig/import` RPC → Hermes session export handoff.

Standing **Adapt** classes:
- Stop hook `{"decision":"block"}` → Hermes `pre_verify` hook (fail-open).
- Background notify (none upstream) → `hermes send`.
