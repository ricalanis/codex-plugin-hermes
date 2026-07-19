# Semantic Spec: `codex-plugin-cc` (reference for the Hermes port)

> Produced 2026-07-19 from `ref/codex-plugin-cc`. This is the porting source-of-truth: we mirror **semantics**, not implementation.

Root: `ref/codex-plugin-cc`, a marketplace repo wrapping a single plugin at `plugins/codex`. All runtime logic is Node ESM driving the **Codex `app-server`** over JSON-RPC (no `codex exec` upstream; our port uses `codex exec` per PRD).

## 1. Inventory

```
.claude-plugin/marketplace.json      # marketplace descriptor
plugins/codex/
  .claude-plugin/plugin.json         # {name: codex, version, description, author OpenAI}
  agents/codex-rescue.md             # subagent def (model: sonnet)
  commands/                          # 8 slash commands
    review.md adversarial-review.md rescue.md transfer.md
    status.md result.md cancel.md setup.md
  hooks/hooks.json                   # SessionStart / SessionEnd / Stop
  prompts/adversarial-review.md
  prompts/stop-review-gate.md
  schemas/review-output.schema.json
  scripts/codex-companion.mjs        # main CLI (~1073 lines), + broker, hooks, lib/ (17 modules)
  skills/codex-cli-runtime/  codex-result-handling/  gpt-5-4-prompting/
```

## 2. Commands (semantics to mirror)

All commands invoke `codex-companion.mjs <subcommand> "$ARGUMENTS"`. Namespace `/codex:<name>`. Most are `disable-model-invocation: true` (user-only).

### /codex:review
- Args: `[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch]`
- Review-only; never fix/patch; return Codex output verbatim.
- Mode logic (run by the model, not the script): `--wait` → foreground; `--background` → background; neither → estimate size via `git status --short --untracked-files=all` + `git diff --shortstat [--cached | <base>...HEAD]`; tiny (~1-2 files) → recommend Wait, else Background; ask user exactly once (two options, recommended first).
- Background message: "Codex review started in the background. Check `/codex:status` for progress."
- Native review only: NO focus text, NO staged/unstaged scopes (script rejects).

### /codex:adversarial-review
- Same flags + optional trailing **focus text** (unlike review). Same mode/ask flow.
- Framing: challenge review — attacks approach/design/tradeoffs/assumptions.

### /codex:rescue
- Args: `[--background|--wait] [--resume|--fresh] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [task text]`
- Invokes the codex-rescue **subagent** (thin forwarder: one call to `task`, return stdout verbatim, no follow-up work).
- `--background`/`--wait` are host-side, NOT forwarded. `--model`/`--effort` forwarded.
- Resume detection: if neither `--resume`/`--fresh`, run `task-resume-candidate --json`; if `available: true` ask user Continue vs Fresh (follow-up phrasing like "continue"/"keep going" → Continue recommended). Continue → `--resume-last`; fresh → fresh thread.
- Codex missing/unauth → point to `/codex:setup`.

### /codex:transfer
- Args: `[--source <jsonl>]`. Direct execution, output presented verbatim; must preserve `Codex session ID: <id>` and `codex resume <id>` lines.
- Upstream: source jail = `~/.claude/projects` realpath check; imports via RPC `externalAgentConfig/import`; ledger at `~/.codex/external_agent_session_imports.json` (match by source_path + content_sha256 → `imported_thread_id`).

### /codex:status
- Args: `[job-id] [--wait] [--timeout-ms <ms>] [--all]`. No id → render compact Markdown table (job ID, kind, status, phase, elapsed, summary, follow-ups). With id → full output verbatim. `--wait` default 240s, poll 2s.

### /codex:result
- Args: `[job-id]`. Present full stored output, no condensing; preserve verdict/findings/file:line/next steps/errors.

### /codex:cancel
- Args: `[job-id]`. Interrupt turn (upstream RPC `turn/interrupt`) + kill process tree; mark job cancelled; log "Cancelled by user."

### /codex:setup
- Args: `[--enable-review-gate|--disable-review-gate]`. Runs `setup --json`. If unavailable + npm present → offer install `npm install -g @openai/codex`, rerun. Installed-but-unauth → guide `codex login`.

## 3. Companion subcommands (10)

| Subcommand | Purpose |
|---|---|
| `setup` | availability/auth check + toggle review gate config |
| `review` | native reviewer (working-tree/branch target) |
| `adversarial-review` | structured adversarial review (JSON schema output) |
| `task` | generic Codex turn (`[--background] [--write] [--resume-last|--fresh] [--model] [--effort] [prompt]`) |
| `transfer` | import host session → Codex thread |
| `task-worker` | internal: detached background executor |
| `status` | job snapshot / list |
| `result` | stored final output of a finished job |
| `task-resume-candidate` | `{available, sessionId, candidate:{id,status,title,summary,threadId,...}|null}` |
| `cancel` | interrupt + kill |

Shared semantics:
- Model alias `spark` → `gpt-5.3-codex-spark`; efforts `{none,minimal,low,medium,high,xhigh}`; `-m` → `--model`, `-C` → `--cwd`.
- Every command supports `--json` (pretty payload) vs rendered markdown.
- Task sandbox: `workspace-write` if `--write` else `read-only`. Reviews always read-only.
- Availability gate: `codex --version` must succeed (upstream also checks app-server). Canonical error: "Codex CLI is not installed… `npm install -g @openai/codex`, then rerun `/codex:setup`."
- `STOP_REVIEW_TASK_MARKER = "Run a stop-gate review of the previous Claude turn."` relabels a task job as stop-gate review.

## 4. State model

- State root: `$CLAUDE_PLUGIN_DATA/state` else `os.tmpdir()/codex-companion`. Per-workspace dir `<slug>-<sha256[:16]>` of git-toplevel path.
- `state.json`: `{version:1, config:{stopReviewGate:false}, jobs:[…]}` (max 50 jobs, sorted by updatedAt).
- `jobs/<jobId>.json` (full record: status, phase, pid, threadId, request, result, sessionId, timestamps) + `jobs/<jobId>.log` (`[iso] message` lines + "Final output" block).
- Job id: `<prefix>-<base36 time>-<random6>`, prefixes `review`/`task`. Statuses: `queued → running → completed|failed|cancelled`.
- Session scoping: jobs carry sessionId; status/result/cancel filter to current session when the session env var is set. Job refs accept unique prefixes.

## 5. Hooks

| Event | Action | Timeout |
|---|---|---|
| SessionStart | export `CODEX_COMPANION_SESSION_ID`, `CODEX_COMPANION_TRANSCRIPT_PATH` into session env | 5s |
| SessionEnd | shutdown shared runtime, kill session's running jobs, cleanup | 5s |
| Stop | **review gate** (below) | 900s |

Stop review gate: OFF by default (`config.stopReviewGate`). When ON: skip if Codex unavailable; else run `task --json` with prompt from `prompts/stop-review-gate.md` (interpolates last assistant message). Parse first line of rawOutput: `ALLOW: <reason>` → let stop through; `BLOCK: <reason>` → block (upstream: `{"decision":"block","reason"}` on stdout). Empty/timeout/parse-failure → **block** with bypass guidance.

## 6. Prompts

**adversarial-review.md** — XML-tagged; placeholders `{{TARGET_LABEL}} {{USER_FOCUS}} {{REVIEW_COLLECTION_GUIDANCE}} {{REVIEW_INPUT}}`. Blocks: `<role>` (break confidence, not validate), `<operating_stance>` (skepticism, no credit for intent), `<attack_surface>` (auth/tenant, data loss, rollback/idempotency, races, null/timeout, version skew, observability), `<review_method>`, `<finding_bar>`, `<structured_output_contract>` (JSON only: verdict approve|needs-attention, findings[severity,title,body,file,line_start,line_end,confidence,recommendation], next_steps), `<grounding_rules>`, `<calibration_rules>` (prefer one strong finding), `<final_check>`, `<repository_context>`.

**stop-review-gate.md** — placeholder `{{CLAUDE_RESPONSE_BLOCK}}`. Only review previous turn; pure status/setup output → ALLOW immediately. Output contract: first line exactly `ALLOW: …` or `BLOCK: …`. BLOCK only if code changed AND something must be fixed. Grounding: verify repo state, don't trust response text; don't block on older edits.

**Review context collection**: inline diff if ≤2 files and ≤256KB (untracked inlined up to 24KB each, binaries skipped); else "self-collect" mode — Codex told to inspect the diff itself with read-only git commands.

## 7. Skills (upstream)

- `codex-cli-runtime` (internal): rescue forwarder contract — call `task` exactly once, return stdout unchanged; flag routing (strip `--background`/`--wait`; map `--resume`→`--resume-last`; default write-capable).
- `codex-result-handling` (internal): present verbatim, findings by severity, exact file:line; **after presenting review findings STOP — never auto-apply fixes**; never fabricate output if Codex never ran.
- `gpt-5-4-prompting`: operator-style XML-tagged prompt recipes (task + output contract + follow-through policy + verification/grounding blocks).

## 8. Host-specific surfaces to re-map for Hermes

| Claude Code | Hermes equivalent |
|---|---|
| `${CLAUDE_PLUGIN_ROOT}` | plugin dir resolution (script`s own dirname) |
| `$CLAUDE_PLUGIN_DATA/state` | `~/.hermes/codex-companion/<workspace-slug>` |
| `$CLAUDE_ENV_FILE` env persistence | state file / env exported by hook |
| hook stdin JSON (`session_id`, `transcript_path`, `last_assistant_message`) | Hermes hook payload schema |
| Stop `{"decision":"block"}` protocol | Hermes hook block mechanism |
| `AskUserQuestion` / `Agent` tools | Hermes ask/delegate_task mechanisms |
| `~/.claude/projects` transfer jail | Hermes session store |
| No notifications | `hermes send -t telegram…` on background completion |
| `codex app-server` JSON-RPC | `codex exec --json` / `-o last-message` / `exec resume` (per PRD) |

Timeouts to mirror: stop gate 15 min; status --wait 240s/poll 2s.
