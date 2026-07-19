# `/codex-transfer`

**Description:** Transfer an exported Hermes session into a persistent, resumable Codex thread.

**Arguments:** `[--source <path>] [--json]`

## Behavior

- Accepts a JSONL or Markdown session export produced by `hermes dump` or the Hermes session exporter.
- Without `--source`, prints export instructions and exits without starting Codex.
- With a source, imports up to the last 100 KB of transcript context and preserves the Codex session ID and `codex resume <id>` command in the output.

## Examples

```text
/codex-transfer --source /tmp/hermes-session.jsonl
/codex-transfer --source /tmp/hermes-session.md --json
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/transfer.md
