# codex-plugin-hermes

A Hermes Agent plugin that mirrors [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) — use Codex from Hermes to review code, delegate tasks, transfer sessions, and manage background jobs.

## Why

Ricardo uses both Hermes Agent and Codex. The official `codex-plugin-cc` lets Claude Code delegate to Codex via 8 slash commands. This project builds the **equivalent for Hermes** — same 8 commands, same semantics, adapted to Hermes' plugin architecture (Python, not Node.js; Hermes slash commands, not Claude Code plugins; `hermes send` for notifications, not Claude's Bash tool).

## Structure

```
codex-plugin-hermes/
├── PRD.md                        # Product requirements
├── plugin.yaml                   # Hermes plugin manifest
├── commands/                     # Slash command definitions (8)
│   ├── review.md
│   ├── adversarial-review.md
│   ├── rescue.md
│   ├── transfer.md
│   ├── status.md
│   ├── result.md
│   ├── cancel.md
│   └── setup.md
├── scripts/
│   └── codex-companion.sh        # Core wrapper around `codex exec` + app-server
├── prompts/
│   ├── adversarial-review.md     # Adversarial review prompt template
│   └── stop-review-gate.md      # Stop-hook review gate prompt
├── hooks/
│   └── hooks.json                # SessionStart / SessionEnd / Stop hooks
├── skills/
│   └── codex-cli-runtime/        # Skill for Codex CLI prompting patterns
└── ref/                          # Read-only reference mirrors (never edit)
    ├── codex-plugin-cc/          # Mirror of openai/codex-plugin-cc
    └── hermes-agent/             # Mirror of NousResearch/hermes-agent (slimmed)
```

## Mirror pattern

The `reference/codex-plugin-cc` directory is a full clone of the original OpenAI plugin. It serves as:

1. **Source of truth for semantics** — every command, hook, prompt, and script in our Hermes plugin mirrors the corresponding file in the reference. When the original changes, we `git pull` in the reference and reflect the changes.
2. **Agentic mirror** — a periodic cron job pulls the reference, diffs against our implementation, and flags drift for review. This is the "pull, reflect" pattern: pull upstream → diff → decide what to port → reflect in our code.
3. **Never modified** — we never edit files inside `reference/`. It's read-only. Our implementation lives in the root of `codex-plugin-hermes/`.

## Pull-Reflect pattern

```
┌─────────────────┐     git pull      ┌─────────────────┐
│  openai/        │ ────────────────> │ reference/      │
│  codex-plugin-cc│                  │ codex-plugin-cc  │
└─────────────────┘                   └─────────────────┘
                                              │
                                              │ diff + analyze
                                              ▼
                                      ┌─────────────────┐
                                      │ codex-plugin-hermes │
                                      │ (our code)        │
                                      └─────────────────┘
```

1. **Pull**: `cd reference/codex-plugin-cc && git pull origin main`
2. **Diff**: Compare each file in `reference/` against our equivalent in the root
3. **Reflect**: For each drift, decide:
   - **Port** — the change is relevant to Hermes → update our code
   - **Skip** — the change is Claude Code-specific (e.g., `${CLAUDE_PLUGIN_ROOT}`, `subagent_type`, `AskUserQuestion`) → skip, document why
   - **Adapt** — the change is relevant but needs Hermes adaptation → port with changes

## Commands (8 — mirroring openai/codex-plugin-cc)

| Command | Original (Claude Code) | Hermes equivalent |
|---|---|---|
| `/codex:review` | `node codex-companion.mjs review` | `codex exec --json "review this diff"` |
| `/codex:adversarial-review` | `node codex-companion.mjs adversarial-review` | `codex exec --json` with adversarial prompt |
| `/codex:rescue` | Subagent → `codex-companion.mjs task` | `codex exec` with task prompt (foreground or background) |
| `/codex:transfer` | `codex-companion.mjs transfer` | `codex resume <session-id>` after session export |
| `/codex:status` | `codex-companion.mjs status` | Read from job state files |
| `/codex:result` | `codex-companion.mjs result` | Read from job output files |
| `/codex:cancel` | `codex-companion.mjs cancel` | `kill` the background process |
| `/codex:setup` | `codex-companion.mjs setup` | `codex --version` + auth check |

## Key adaptations (Hermes vs Claude Code)

1. **Language**: Node.js → Bash + Python (Hermes plugins are shell/Python, not JS)
2. **App-server**: Original spawns Codex app-server via JSON-RPC broker. Hermes already has `/codex-runtime` integration and `hermes-tools` MCP registered in Codex. We use `codex exec` (CLI) for simplicity, or `/codex-runtime codex_app_server` for the full app-server path.
3. **Slash commands**: Claude Code's `commands/*.md` → Hermes slash commands (gateway `slash_commands.py` or plugin `commands/` in manifest)
4. **Subagents**: Claude Code's `Agent` tool → Hermes' `delegate_task`
5. **Background jobs**: Claude Code's `Bash(run_in_background: true)` → Hermes' `terminal(background=true, notify_on_complete=true)`
6. **Notifications**: Claude Code has none → Hermes sends to Telegram Code thread via `hermes send`
7. **Session transfer**: Claude Code's JSONL → Hermes' session DB export
8. **Review gate**: Claude Code's Stop hook → Hermes' `hooks.Stop` in `hooks.json`

## Non-goals

- **Not** a port of the Node.js app-server broker. Hermes has its own runtime; we use `codex exec` or the existing `/codex-runtime` integration.
- **Not** a 1:1 line-by-line translation. We mirror semantics, not implementation.
- **Not** a replacement for `codex-plugin-cc` in Claude Code. Both can coexist.

## Status

- [x] Project scaffold created
- [x] Reference cloned
- [x] PRD written (this file)
- [x] plugin.yaml manifest
- [x] 8 slash commands (`/codex-review` … `/codex-setup`, registered via `register(ctx)`)
- [x] codex-companion.sh core script (10 subcommands, verified end-to-end against codex-cli 0.144.6)
- [x] Prompts (adversarial-review, stop-review-gate) — ported with placeholder/block parity
- [x] Hooks (`on_session_end`, `pre_verify` stop review gate — fail-open, off by default)
- [x] Pull-reflect loop (`.claude/skills/pull-reflect` + deterministic `check-drift.sh`; cron recipe documented)
- [x] Tests (`tests/acceptance.sh` — 40 checks, green; shellcheck + py_compile clean)
- [x] First working command (`/codex-setup`) — plus task/review/status/result/cancel/resume verified live