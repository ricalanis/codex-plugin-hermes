---
name: pull-reflect
description: Sync upstream mirrors in ref/, diff against our port, and reflect drift into the Hermes plugin.
---

# Pull-Reflect: autonomous upstream drift sync

Keeps codex-plugin-hermes aligned with its two upstreams. Run when asked to "sync upstream", "check drift", or on a schedule.

## The loop

1. **Detect** — cheap, clones nothing:
   ```bash
   .claude/skills/pull-reflect/scripts/check-drift.sh
   ```
   It compares live upstream HEADs against `upstream.lock` (committed), which records the commits this repo was last reconciled against. This works with an empty `ref/`, so it runs anywhere.

   Exit `0` → checked: either `no drift` (stop here) or a drift summary. Exit `2` → **CANNOT CHECK**: no network, or a missing/incomplete lockfile — nothing was verified. Never treat exit 2 as all-clear.

   Only when there IS drift, clone the mirrors to read the changed source:
   ```bash
   .claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap
   ```
   Mirrors are read-only and never committed: never edit their contents.

2. **Diff**: for `ref/codex-plugin-cc`, list changed files between old and new HEAD (`git -C ref/codex-plugin-cc diff --stat <old>..<new>`). Map each to our port surface:
   | Upstream path | Our file |
   |---|---|
   | `plugins/codex/commands/<n>.md` | `commands/<n>.md` + handler in `__init__.py` |
   | `plugins/codex/scripts/codex-companion.mjs` + `lib/` | `scripts/codex-companion.sh` |
   | `plugins/codex/prompts/*` | `prompts/*` (placeholder tokens are kept identical on purpose) |
   | `plugins/codex/schemas/*` | `schemas/*` |
   | `plugins/codex/hooks/hooks.json` + hook scripts | `pre_verify` / `on_session_end` in `__init__.py` |
   | `plugins/codex/skills/*` | `skills/codex-cli-runtime/SKILL.md` |
   For `ref/hermes-agent`, only care about changes to `hermes_cli/plugins.py` (hook/ctx signatures), `gateway/hooks.py`, `hermes_cli/send_cmd.py`, and skill frontmatter rules in `AGENTS.md`.

3. **Reflect** — per drift item decide, citing the diff:
   - **Port**: semantics changed and applies to Hermes → delegate the edit to Codex (see the `supervise-codex` skill), with the upstream diff pasted into the brief.
   - **Skip**: Claude-Code-specific (`${CLAUDE_PLUGIN_ROOT}`, `AskUserQuestion`, `Agent` tool, broker/app-server internals, `$CLAUDE_ENV_FILE`) → record in `docs/drift-log.md` with one-line justification.
   - **Adapt**: relevant but needs Hermes translation (host env vars, notification path, hook shape) → delegate with the adaptation spelled out.

4. **Verify**: `bash tests/acceptance.sh` must print `0 failed`. Semantics changes also need the relevant contract in `SPEC.md` updated (manager edit, not Codex).

5. **Record and release the lock**: append to `docs/drift-log.md` (date, upstream commit range, per-file Port/Skip/Adapt decision and outcome), update `docs/changelog.md`, then:
   ```bash
   .claude/skills/pull-reflect/scripts/check-drift.sh --update-lock
   ```
   Without this the same drift is reported every run forever. Update the lock **only** for drift you actually triaged — doing it otherwise silently discards an upstream change.

## Scheduling it (optional)

The detector half of this loop is deterministic and runs without an LLM. `hermes cron --script` requires the script to live under `~/.hermes/scripts/`, so link it there first:

```bash
ln -sf ~/dev/codex-plugin-hermes/.claude/skills/pull-reflect/scripts/check-drift.sh \
       ~/.hermes/scripts/codex-plugin-drift.sh
hermes cron create '0 9 * * 1' --name codex-plugin-drift \
  --script codex-plugin-drift.sh --no-agent --deliver telegram
```

Empty stdout ("no drift") is silent, so it only pings when upstream actually moved. Triage (steps 2-3 above) stays agent-driven: run this skill in a session with `--workdir` on the repo so `AGENTS.md` loads.

## Invariants

- `ref/` contents are never edited by hand; only `git pull`.
- `tests/acceptance.sh` only gets *stronger* — checks are added for ported behavior, never weakened to make a port pass.
- Placeholder tokens in `prompts/` stay byte-identical to upstream so this loop's diffs stay meaningful.
