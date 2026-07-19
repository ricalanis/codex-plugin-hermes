# `/codex-status`

**Description:** Show active and recent Codex jobs for the current workspace.

**Arguments:** `[job-id] [--all] [--json]`

## Behavior

- Without a job ID, shows non-terminal jobs and the five most recent terminal jobs in a compact table; `--all` shows every retained job.
- With a full ID or unique prefix, shows job details and the last 20 log lines.
- `--json` emits machine-readable state.

## Examples

```text
/codex-status
/codex-status --all
/codex-status task-abc123 --json
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/status.md
