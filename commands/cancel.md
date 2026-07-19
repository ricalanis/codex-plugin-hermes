# `/codex-cancel`

**Description:** Cancel an active background Codex job in the current workspace.

**Arguments:** `[job-id]`

## Behavior

- Accepts a full job ID or unique prefix and terminates its detached worker process group.
- If exactly one job is queued or running, the job ID may be omitted. If several are active, an ID is required.
- Marks the job `cancelled` and records `Cancelled by user.` in its log.

## Examples

```text
/codex-cancel
/codex-cancel task-abc123
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/cancel.md
