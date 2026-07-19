# `/codex-result`

**Description:** Show the complete stored output for a finished Codex job in the current workspace.

**Arguments:** `[job-id] [--json]`

## Behavior

- Without a job ID, selects the most recent completed job. A full ID or unique prefix selects a specific job.
- Presents the final output verbatim, including findings, exact file and line locations, parse errors, the Codex session ID, and the `codex resume <id>` command.
- For unfinished jobs, reports the current status and points to `/codex-status`.

## Examples

```text
/codex-result
/codex-result review-abc123
/codex-result task-abc123 --json
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/result.md
