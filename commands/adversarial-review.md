# `/codex-adversarial-review`

**Description:** Challenge an implementation's design choices, tradeoffs, assumptions, and failure modes with a read-only Codex review.

**Arguments:** `[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch] [focus ...]`

## Behavior

- Uses the same working-tree and branch targeting rules as `/codex-review`, but accepts trailing focus text.
- Returns a structured verdict, severity-sorted findings with exact file and line locations, and next steps. It never applies fixes.
- `--wait` returns the review. `--background` returns a job ID immediately. Without either flag, reviews of at most two files and 200 changed lines wait; larger reviews run in the background.

## Examples

```text
/codex-adversarial-review
/codex-adversarial-review --base main challenge the retry design
/codex-adversarial-review --background look for races and rollback failures
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/adversarial-review.md
