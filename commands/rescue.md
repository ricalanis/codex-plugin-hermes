# `/codex-rescue`

**Description:** Delegate investigation, an explicit fix, or follow-up implementation work to Codex.

**Arguments:** `[--background|--wait] [--resume|--fresh] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [task text]`

## Behavior

- Runs one Codex task and presents its output verbatim. `--wait` is the foreground default; `--background` returns a job ID immediately.
- `--resume` continues the newest resumable task thread; `--fresh` starts a new thread. A request without task text needs an explicit task unless it resumes a prior thread.
- Model and effort are passed through. `spark` maps to `gpt-5.3-codex-spark`.
- If Codex is unavailable or unauthenticated, run `/codex-setup`.

## Examples

```text
/codex-rescue investigate why the tests fail
/codex-rescue --resume apply the top fix
/codex-rescue --background --model spark fix the regression
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/rescue.md
