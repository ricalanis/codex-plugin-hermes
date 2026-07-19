---
name: codex-cli-runtime
description: Run Codex tasks and present their results safely.
platforms: [linux, macos]
metadata:
  hermes:
    tags: [codex, delegation]
    category: devops
---

# Codex CLI Runtime

Use the plugin companion at `scripts/codex-companion.sh`. A rescue handoff invokes
`task` exactly once and returns its stdout unchanged. Do not inspect the repository,
poll jobs, or do follow-up implementation inside that forwarder.

## Routing

| User flag | Companion routing |
|---|---|
| `--wait` | Strip it; run the task in the foreground. |
| `--background` | Strip it from prompt text; pass `--background`. |
| `--resume` | Strip it; pass `--resume-last`. |
| `--fresh` | Strip it; pass `--fresh`. |
| `--model spark` | Pass `--model gpt-5.3-codex-spark`. |
| `--effort VALUE` | Pass one of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`. |

Default rescue work to `task --write` unless the user explicitly asks for read-only
review, diagnosis, or research. Preserve the user's task text apart from routing
flags. Leave model and effort unset unless the user supplied them.

## Result handling

- Present Codex output verbatim. Preserve verdict, findings, next steps, and all
  `Codex session ID:` and `Resume in Codex:` lines.
- Present review findings in severity order and retain exact `file:line` locations.
- After presenting review findings, STOP. Never auto-apply fixes; ask which findings
  the user wants fixed before editing.
- Never fabricate a substitute result when Codex did not run or returned malformed
  output. Include actionable errors and stop.
- If Codex is unavailable or unauthenticated, direct the user to `/codex-setup`.
