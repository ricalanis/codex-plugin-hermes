# ref/

Read-only reference projects for `codex-plugin-hermes`. Never edit files here.

## Projects

### codex-plugin-cc
Mirror of https://github.com/openai/codex-plugin-cc
- The original Claude Code plugin we're mirroring for Hermes
- 8 slash commands, app-server broker, review gate, session transfer
- Source of truth for command semantics

### hermes-agent
Mirror of https://github.com/NousResearch/hermes-agent (~236 MB, full source)
- The platform we port **to**. This is the source of truth for every Hermes API question —
  read it rather than guessing or trusting a prose summary.
- `hermes_cli/plugins.py` — manifest fields, the `register(ctx)` surface, `VALID_HOOKS`,
  and each hook's exact kwargs and return contract (including `pre_verify`, our stop gate)
- `hermes_cli/plugins_cmd.py` — install/enable mechanics · `hermes_cli/send_cmd.py` — notifications
- `tools/` — `delegate_task`, `terminal`, and the rest of the tool surface
- `AGENTS.md` — Hermes' own plugin authoring rules

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