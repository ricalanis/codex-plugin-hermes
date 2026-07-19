# `/codex-review`

**Description:** Run a read-only Codex review against the repository's local Git state.

**Arguments:** `[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch]`

## Behavior

- Uses Codex's native reviewer and never applies fixes.
- `working-tree` reviews uncommitted changes; `branch` compares against `--base` or the detected default branch; `auto` selects between them.
- `--wait` returns the reviewer output verbatim. `--background` returns a job ID immediately. Without either flag, reviews of at most two files and 200 changed lines wait; larger reviews run in the background.
- Custom focus text is rejected. Use `/codex-adversarial-review` for a steerable review.

## Examples

```text
/codex-review
/codex-review --wait --scope working-tree
/codex-review --background --base main --scope branch
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/review.md
