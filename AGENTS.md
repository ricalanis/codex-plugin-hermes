# AGENTS.md — how agents work in this repo

Read this before changing anything. Applies to Codex, Claude, and any Hermes agent session.

## Roles

- **Codex = senior developer.** Writes all plugin implementation: `plugin.yaml`, `__init__.py`, `commands/`, `scripts/`, `prompts/`, `schemas/`, `skills/`, `README.md`.
- **Claude = senior technical manager.** Owns `SPEC.md`, `tests/acceptance.sh`, `docs/`, `.claude/skills/`. Specs the work, delegates it, verifies it. Does not implement plugin code unless Codex fails twice on the same item.

## Contracts

1. `SPEC.md` is the implementation contract. Section 0 decisions are fixed — do not relitigate them mid-task.
2. `tests/acceptance.sh` is the verification contract. Implementation must pass it **unmodified**; it only ever gets stronger. If spec and test conflict, implement to the test and flag the conflict.
3. `ref/` is a read-only upstream mirror (`ref/codex-plugin-cc`, `ref/hermes-agent`). Never edit its contents; `git pull` is the only permitted write.

## Definition of done

```bash
bash tests/acceptance.sh                    # must print "0 failed"
shellcheck -S warning scripts/codex-companion.sh
python3 -m py_compile __init__.py
```

Then update `docs/changelog.md`. Commit only when the user asks.

## Skills

Load these by name; they cover the three recurring jobs in this repo.

- `.claude/skills/maintain` — health checks, live smoke tests, job-state upkeep, dependency updates. **Start here** for "is it healthy?" or "something broke".
- `.claude/skills/pull-reflect` — sync upstream mirrors, triage drift (Port / Skip / Adapt), record in `docs/drift-log.md`. Deterministic detector: `.claude/skills/pull-reflect/scripts/check-drift.sh [--notify]`.
- `.claude/skills/supervise-codex` — how to brief Codex and verify contract-first.

## Dependencies

`dependencies.yaml` declares them; `scripts/doctor.sh` checks them (`--json` for machine output). Required: bash, codex CLI ≥0.144, jq, git, and standard POSIX tools. Optional: `hermes` (notifications only), `setsid` (Linux fast path). Dev: shellcheck, python3.

## Design north star

This plugin mirrors `openai/codex-plugin-cc` **semantically** for a general-purpose agent (Hermes), not a coding-only one. Keep it simple: one Bash companion over `codex exec`, reply-only slash commands, file-backed job state, `hermes send` for notifications. No app-server broker, no Node.

## Traceability (required)

- `docs/changelog.md` — what changed.
- `docs/known_issues.md` — mistakes + how to avoid repeating them.
- `docs/decisions.md` — process/architecture decisions.
- `docs/drift-log.md` — upstream drift triage.
