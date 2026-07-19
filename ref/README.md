# ref/

Read-only reference projects for `codex-plugin-hermes`. Never edit files here.

## Projects

### codex-plugin-cc
Mirror of https://github.com/openai/codex-plugin-cc
- The original Claude Code plugin we're mirroring for Hermes
- 8 slash commands, app-server broker, review gate, session transfer
- Source of truth for command semantics

### hermes-agent
Mirror of https://github.com/NousResearch/hermes-agent
- Hermes Agent source (slimmed — plugin system, slash commands, hooks, gateway only)
- Reference for plugin architecture: `plugins/*.yaml` manifests, `gateway/slash_commands.py`, hooks system
- How Hermes plugins are structured, how slash commands are registered, how hooks fire

## Bootstrap

These mirrors are **not committed** — they are upstream code and we don't redistribute it. Clone them on demand:

```bash
.claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap
```

That clones both repositories here as real git clones, which is what the drift loop needs.

## Update

```bash
.claude/skills/pull-reflect/scripts/check-drift.sh
```

Exit codes: `0` checked (prints `no drift` or a drift summary), `2` **cannot check** — a mirror is missing or is not a git clone, so nothing was verified. A missing mirror must never read as "all clear".

Add `--notify [target]` to push the result through `hermes send`. See `.claude/skills/pull-reflect/SKILL.md` for the triage loop and the cron recipe.