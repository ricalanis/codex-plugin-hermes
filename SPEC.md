# SPEC — codex-plugin-hermes v0.1

Implementation spec for the Hermes port of `codex-plugin-cc`. Written by the technical manager (Claude); implemented by the senior developer (Codex). Verified only against `tests/acceptance.sh` — read that contract first.

Sources of truth (read before coding):
- `docs/research/codex-plugin-cc-semantics.md` — upstream semantics we mirror.
- `docs/research/hermes-extension-architecture.md` — Hermes extension formats (verified against `ref/hermes-agent` source; cite lines from `hermes_cli/plugins.py` when in doubt).
- `ref/` is **read-only**. Never edit anything under it.

## 0. Design decisions (fixed — do not relitigate)

1. Hermes-native plugin: `plugin.yaml` + `__init__.py:register(ctx)`. No Node. Core logic in **one** Bash script (`scripts/codex-companion.sh`) wrapping `codex exec` (CLI, v0.144+), not the app-server JSON-RPC broker.
2. Reply-only slash commands (`ctx.register_command`). No AskUserQuestion analog: interactive decisions upstream become **deterministic companion logic** + flags.
3. Hooks live in `__init__.py` (`on_session_end` cleanup, `pre_verify` stop gate). No `hooks/hooks.json`.
4. Background jobs = detached worker processes + file-backed job state + `hermes send` Telegram notification on completion. Notification failure is never fatal.
5. Stop gate is **fail-open** (upstream is fail-closed): on gate error/timeout, log and allow. A general agent on Telegram must not brick on plugin errors.
6. Job state is workspace-scoped, not session-scoped (v1 simplification).
7. Keep it simple: no broker, no session-id env plumbing, no streaming. Mirror upstream *semantics and output shapes*, not internals.

## 1. Deliverables (file tree)

```
plugin.yaml                      # Hermes manifest
__init__.py                      # register(ctx): 8 commands + 2 hooks
commands/                        # 8 port-contract docs (markdown, mirror upstream command behavior)
  review.md adversarial-review.md rescue.md transfer.md
  status.md result.md cancel.md setup.md
scripts/codex-companion.sh       # the core CLI (bash, ~all logic)
prompts/adversarial-review.md    # ported template (placeholders preserved)
prompts/stop-review-gate.md      # ported template
schemas/review-output.schema.json
skills/codex-cli-runtime/SKILL.md
tests/acceptance.sh              # PROVIDED — do not weaken; make it pass
README.md                        # last step, style of ref/codex-plugin-cc/README.md
```

## 2. plugin.yaml

```yaml
name: codex
version: 0.1.0
description: Use Codex from Hermes to review code, delegate tasks, transfer sessions, and manage background jobs.
author: Ricardo Alanis
kind: standalone
platforms: [linux, macos]
requires_env: []
provides_tools: []
provides_hooks: [pre_verify, on_session_end]
```

## 3. `__init__.py`

- Top-level `register(ctx)` (see `ref/hermes-agent/plugins/disk-cleanup/__init__.py` as the canonical template; hook names/kwargs documented at `ref/hermes-agent/hermes_cli/plugins.py:135-215`).
- Registers 8 commands (names, `args_hint` mirrors upstream `argument-hint`):
  `codex-review`, `codex-adversarial-review`, `codex-rescue`, `codex-transfer`, `codex-status`, `codex-result`, `codex-cancel`, `codex-setup`.
- Every handler: `subprocess.run([COMPANION, <subcommand>, raw_args], capture_output=True, text=True, timeout=...)` → return stdout (stderr appended on nonzero exit). Companion path resolved relative to `__init__.py` (`Path(__file__).parent / "scripts/codex-companion.sh"`).
- Timeouts: status/result/cancel/setup/transfer 60s; review/adversarial/rescue 1800s (foreground runs can be long; background returns immediately).
- Hooks:
  - `on_session_end` → `codex-companion.sh session-end` (kill this workspace's running jobs' orphaned workers ONLY if `--cleanup-on-session-end` was configured; default: no-op beyond log-prune). Keep minimal.
  - `pre_verify` → stop gate, §6.
- Python: stdlib only, no third-party imports. Must `python3 -m py_compile` clean.

## 4. `scripts/codex-companion.sh` — subcommand contracts

Bash ≥5, `set -euo pipefail`, shellcheck-clean (or documented disables). Single file. `--json` supported where specified (pretty JSON to stdout). All state under:

- `STATE_ROOT` = `$CODEX_COMPANION_STATE_ROOT` if set, else `${HERMES_HOME:-$HOME/.hermes}/codex-companion`.
- Per-workspace dir: `<slug>-<sha16>` where slug = sanitized basename of `git rev-parse --show-toplevel` (else cwd), sha16 = first 16 hex of sha256 of that absolute path. (Mirror upstream.)
- `state.json` = `{"version":1,"config":{"stop_review_gate":false},"jobs":[...]}` (jobs pruned to 50, newest first by updated_at).
- `jobs/<jobId>.json` + `jobs/<jobId>.log` + `jobs/<jobId>.last` (last-message file from `codex exec -o`).
- Job id: `<review|task>-<epoch36>-<rand6>`. Statuses: `queued|running|completed|failed|cancelled`.
- Use `jq` for all JSON (declare dependency; `setup` checks it).

Codex invocation base: `codex exec --json --skip-git-repo-check=false -C <workspace>` with `-o <job>.last`; sandbox: `--sandbox read-only` default, `--sandbox workspace-write` for `task --write`. Model: `--model` passthrough; alias `spark` → `gpt-5.3-codex-spark`. Effort: `-c model_reasoning_effort="<v>"` with validation set `{none,minimal,low,medium,high,xhigh}` (verify the exact config key against `codex exec --help`/docs; if unsupported, drop with a warning line). Parse the JSONL event stream to capture the thread/session id (run `codex exec --json 'say ok'` once during development to confirm the event name — record it in a comment).

| Subcommand | Contract |
|---|---|
| `setup [--json] [--enable-review-gate\|--disable-review-gate]` | Checks: codex binary + `codex --version`; auth (`codex login status` exit code; treat nonzero as "not authenticated"); `jq` present; `hermes send` available (`command -v hermes`); state dir writable. Gate flags toggle `config.stop_review_gate`. JSON keys: `{codex_available, codex_version, authenticated, jq_available, hermes_send_available, state_dir, review_gate}`. Human render: "# Codex Setup" + check list + next steps (`codex login` when unauthenticated; install hint `npm install -g @openai/codex` when missing). |
| `review [--wait\|--background] [--base <ref>] [--scope auto\|working-tree\|branch] [args...]` | Rejects focus text (mirror upstream: native review only). Target: `--scope working-tree` → `codex exec review --uncommitted`; `branch` → `--base <ref\|detected default>`; `auto` → dirty tree ? working-tree : branch (default branch via `origin/HEAD`, fallback main/master). Mode: `--wait` fg, `--background` bg; neither → **auto**: fg if changed files ≤2 AND changed lines ≤200 (`git diff --shortstat` etc.), else bg with message `Codex review started in the background as <jobId>. Check /codex-status for progress.` Fg: run, print reviewer output verbatim. |
| `adversarial-review [flags as review] [focus text...]` | Focus text allowed. Build prompt from `prompts/adversarial-review.md` (envsubst-style replace of `{{TARGET_LABEL}} {{USER_FOCUS}} {{REVIEW_COLLECTION_GUIDANCE}} {{REVIEW_INPUT}}`). Context: inline diff if ≤2 files and ≤256KB else self-collect guidance (tell Codex to run read-only git itself). Run `codex exec --json --output-schema schemas/review-output.schema.json --sandbox read-only`. Render: `# Codex Adversarial Review`, Verdict, findings sorted by severity `[sev] title (file:line_start)` + body + recommendation, Next steps. Parse failure → print raw output + parse-error note (never crash). Same fg/bg logic as review. |
| `task [--background] [--write] [--resume-last\|--fresh] [--model m] [--effort e] [prompt...]` | Generic turn. `--resume-last`: `codex exec resume <thread-id> <prompt>` using newest completed task job's thread id (error if none / if one is running). Default resume prompt when none given: "Continue from the current thread state. Pick the next highest-value step and execute it." Fg prints Codex last message verbatim + `Codex session ID: <id>` + `Resume in Codex: codex resume <id>`. Bg: queued job + detached worker (below) + immediate `"<title>" started in the background as <jobId>.` |
| `task-worker <jobId>` | Internal. Re-reads job request json, executes, updates job json through running→completed/failed, appends log, then notifies: `hermes send -q -t "${CODEX_COMPANION_NOTIFY_TARGET:-telegram}" -s "Codex <kind> <status>" "<summary + follow-up cmds>"` — failures ignored. Worker is spawned `setsid nohup ... >/dev/null 2>&1 &` so it survives the parent. |
| `transfer [--source <path>] [--json]` | `--source` = a Hermes session export (jsonl or markdown from `hermes dump` / session export). Missing → print how to export and exit 1. With source: build handoff prompt ("You are taking over this conversation from Hermes. Transcript follows...") truncated to last ~100KB, run `codex exec --json`, capture thread id, print `Transferred the Hermes session into a Codex thread.` + `Codex session ID: <id>` + `Resume in Codex: codex resume <id>`. |
| `status [job-id] [--all] [--json]` | No id → markdown table of this workspace's jobs (ID, kind, status, phase, elapsed, summary) newest-first (default: non-terminal + last 5 terminal; `--all` = everything) + follow-up hint line. With id (unique-prefix match, ambiguity error) → full detail incl. log tail (20 lines). |
| `result [job-id] [--json]` | Stored final output verbatim (from `.last` / log "Final output" block) + session-id + resume lines. No id → most recent completed job. Not finished → say status + point to `/codex-status`. |
| `task-resume-candidate [--json]` | `{available:bool, candidate:{id,status,title,summary,thread_id,updated_at}|null}` — newest completed task job with a thread id. |
| `cancel [job-id]` | Resolve running/queued job (id required if several). Kill worker process group (`kill -- -<pgid>` fallback `kill <pid>`), mark cancelled, log "Cancelled by user." Print confirmation. |
| `session-end` | Internal (hook). Prune logs/jobs beyond cap. No output. |
| `help` / no args | Usage listing all subcommands + flags. Exit 0. Unknown subcommand → usage on stderr, exit 1. |

## 5. Commands docs (`commands/*.md`)

Each of the 8 files: short markdown mirroring the upstream command's user-facing contract (description, args, behavior, examples with `/codex-<name>`), plus a `Upstream: ref/codex-plugin-cc/plugins/codex/commands/<name>.md` line (used by the pull-reflect drift loop). These are documentation contracts, not executed code.

## 6. Stop review gate (`pre_verify` hook)

- Read `config.stop_review_gate` from workspace state.json; false (default) → return None immediately (zero overhead).
- When true: extract the assistant's final message from the hook kwargs (check exact signature in `ref/hermes-agent/hermes_cli/plugins.py:135-215`); run `codex-companion.sh task --json "<stop-gate prompt>"` with 900s timeout; prompt from `prompts/stop-review-gate.md` interpolating `{{CLAUDE_RESPONSE_BLOCK}}` (rename internal placeholder to the same token for drift-diff ease).
- First line of Codex output `ALLOW: ...` → return None. `BLOCK: <reason>` → return `{"decision":"block","reason":"Codex stop gate: <reason>"}`.
- Any error/timeout/unparseable → log to stderr, return None (fail-open, decision §0.5).

## 7. Prompts + schema

Port `ref/codex-plugin-cc/plugins/codex/prompts/*.md` and `schemas/review-output.schema.json` with minimal edits: replace "Claude"-host references with Hermes where user-facing, keep XML block structure and placeholder tokens **identical** (drift diffing depends on it). Schema: keep field names/enums exactly (`verdict: approve|needs-attention`, findings fields, `additionalProperties:false`).

## 8. Skill (`skills/codex-cli-runtime/SKILL.md`)

Hermes skill format (frontmatter hardline: `description` ≤60 chars, one sentence, ends with a period; `platforms: [linux, macos]`; `metadata.hermes.tags: [codex, delegation]`, `category: devops`). Content merges upstream `codex-cli-runtime` + `codex-result-handling` contracts:
- How to run companion subcommands; flag routing table (strip `--wait/--background` host-side; `--resume`→`--resume-last`; `spark` alias; efforts list).
- Presentation rules: verbatim output, findings by severity with exact file:line, preserve session-id/resume lines, **after presenting review findings STOP — never auto-apply fixes**, never fabricate output if Codex never ran, unauth → `/codex-setup`.

## 9. Out of scope for Codex (manager-owned)

- `tests/acceptance.sh` (provided; if a contract detail conflicts with this spec, the test wins — flag the conflict, don't edit the test).
- `.claude/skills/` project skills, pull-reflect cron, docs/ updates, final README review (Codex drafts README; manager reviews).

## 10. README.md (final step)

Follow `ref/codex-plugin-cc/README.md` structure/tone: what it is, install (`hermes plugins install` / local dir + `plugins.enabled`), the 8 commands table with examples, background jobs + notifications, review gate, session transfer, Requirements (codex ≥0.144, jq, hermes), development (acceptance tests), pull-reflect note, license/attribution to openai/codex-plugin-cc.
