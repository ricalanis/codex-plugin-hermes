# Codex plugin for Hermes Agent

Use Codex from inside Hermes Agent for read-only code reviews, delegated tasks, resumable session transfers, and background jobs.

This Hermes-native port mirrors the user-facing semantics of [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc). It uses `codex exec`, Hermes slash commands and hooks, and file-backed workspace state; it does not run the upstream Node.js app-server broker.

## What You Get

- Normal and adversarial Codex reviews
- Delegated rescue tasks with foreground, background, fresh, and resume modes
- Workspace-scoped status, result, and cancellation commands
- Hermes-to-Codex transfer and an optional stop-time review gate

## Requirements

- Bash 4 or later, `git`, `jq` 1.6 or later, and a standard POSIX userland
- Codex CLI 0.144 or later, installed and authenticated (`npm install -g @openai/codex`, then `codex login`)

The `hermes` CLI is optional and used only to send background-job notifications. `setsid` is optional; when unavailable (including on macOS) the companion uses a portable `nohup` fallback.

Hermes has no mechanism for declaring binary prerequisites in a plugin manifest, so check them yourself:

```bash
./scripts/doctor.sh          # human-readable dependency report
./scripts/doctor.sh --json   # machine-readable, exits non-zero if a required dep is missing
```

`dependencies.yaml` is the declaration `doctor.sh` enforces.

## Install by asking Hermes

Paste this into a Hermes session and it will install the plugin itself:

> Install the Codex plugin from `ricalanis/codex-plugin-hermes`.
>
> 1. Check `codex --version` first — it must be 0.144 or later. If it's missing, tell me and stop; install it with `npm install -g @openai/codex`.
> 2. Run `hermes plugins install ricalanis/codex-plugin-hermes --enable`. The `--enable` flag is required: without it a non-interactive install lands **disabled** and silently does nothing.
> 3. Verify with `hermes plugins list --json` — look for the plugin named **`codex`** (not `codex-plugin-hermes`; the name comes from the manifest, not the repo) and confirm it is enabled.
> 4. Run `hermes gateway restart`.
> 5. Then run `/codex-setup` and show me the output. If it reports unauthenticated, tell me to run `codex login`.
>
> If any step fails, stop and report which one — don't continue past a failure.

Everything after step 1 is inside the plugin's own README, so an agent that fetches this page can follow it unattended. The manual equivalent is below.

## Install

```bash
# 1. Prerequisite — Hermes will not check this for you.
command -v codex >/dev/null || { echo "MISSING: codex CLI — npm install -g @openai/codex"; exit 1; }

# 2. Install and enable. --enable is REQUIRED for non-interactive installs.
hermes plugins install ricalanis/codex-plugin-hermes --enable

# 3. Verify — expect the plugin named "codex" with status enabled.
hermes plugins list --json | grep -A3 '"codex"'

# 4. Load it.
hermes gateway restart
```

**`--enable` is not optional when an agent runs this.** Without it, Hermes prompts interactively; when stdin is not a TTY it takes the silent default and installs the plugin **disabled**, so nothing works and nothing says why.

**The installed plugin is named `codex`, not `codex-plugin-hermes`.** The install directory and the `plugins.enabled` key both come from `name:` in `plugin.yaml`, not from the repository name. Verify for `codex`.

Enabling writes into `~/.hermes/config.yaml`, which you can also edit directly — plugins load only when allow-listed:

```yaml
plugins:
  enabled:
    - codex
```

For local development, symlink the checkout instead of installing:

```bash
ln -s /path/to/codex-plugin-hermes ~/.hermes/plugins/codex
hermes plugins enable codex
```

Remove that symlink (`rm ~/.hermes/plugins/codex`) before switching to a git install — the installer rejects a destination that resolves outside the plugins directory.

Then confirm the runtime from inside Hermes:

```text
/codex-setup
```

## Commands

| Command | Purpose | Example |
|---|---|---|
| `/codex-review` | Run Codex's native read-only review | `/codex-review --background` |
| `/codex-adversarial-review` | Challenge design choices and assumptions | `/codex-adversarial-review --base main question the retry design` |
| `/codex-rescue` | Delegate investigation or implementation | `/codex-rescue --background fix the failing test` |
| `/codex-transfer` | Import an exported Hermes session into Codex | `/codex-transfer --source /tmp/session.jsonl` |
| `/codex-status` | List jobs or inspect one job | `/codex-status task-abc123` |
| `/codex-result` | Print a finished job's complete output | `/codex-result task-abc123` |
| `/codex-cancel` | Cancel a queued or running job | `/codex-cancel task-abc123` |
| `/codex-setup` | Check readiness or toggle the review gate | `/codex-setup --enable-review-gate` |

Reviews are read-only. `/codex-review` uses native review targeting and rejects custom focus text; `/codex-adversarial-review` accepts focus text but still never changes files. After presenting review findings, stop and decide separately whether to apply them.

## Background Jobs and Notifications

Pass `--background` to a review or rescue task to get a job ID immediately. Detached workers outlive the command process and keep state under the Hermes home directory, scoped by workspace.

```text
/codex-rescue --background investigate the flaky integration test
/codex-status
/codex-result task-abc123
```

On completion or failure the worker notifies through `hermes send`. The default target is Telegram; set `CODEX_COMPANION_NOTIFY_TARGET` to override. Notification failure is ignored and never changes the job result.

Cancelling a job terminates the worker and the Codex process it spawned, so no orphans are left behind.

## Optional Review Gate

The stop-time review gate is disabled by default and configured per workspace:

```text
/codex-setup --enable-review-gate
/codex-setup --disable-review-gate
```

When enabled, Codex inspects the final Hermes response before the turn completes. A grounded `BLOCK:` asks Hermes to keep working and fix the issue; `ALLOW:` lets it finish.

The gate **fails open**: errors, timeouts, an unavailable Codex, or an unparseable response all allow completion. A general-purpose agent must never be trapped mid-conversation by a plugin fault. (Upstream fails closed, which suits a coding-only tool.)

Expect an extra Codex turn and additional usage per stop. Enable it when that tradeoff pays.

## Transfer a Hermes Session

Export a Hermes session as JSONL or Markdown, then pass its path:

```bash
hermes dump --help
```

```text
/codex-transfer --source /tmp/hermes-session.jsonl
```

The command sends the tail of the transcript to a new Codex thread and prints `Codex session ID: <id>` and `codex resume <id>`. Keep those lines — they are how you get back in.

## Maintenance

The repository is built to be maintained by agents. `AGENTS.md` (symlinked as `CLAUDE.md`) is loaded automatically by sessions started with `--workdir` and points at three skills:

| Skill | Use it for |
|---|---|
| `.claude/skills/maintain` | Health checks, live smoke tests, job-state repair, dependency updates |
| `.claude/skills/pull-reflect` | Syncing the upstream mirrors and triaging drift |
| `.claude/skills/supervise-codex` | Delegating implementation and verifying it contract-first |

Verification gates:

```bash
bash tests/acceptance.sh
shellcheck -S warning scripts/codex-companion.sh scripts/doctor.sh
python3 -m py_compile __init__.py
```

`tests/acceptance.sh` is the contract. It must never be weakened to accommodate an implementation, and it reports skipped checks explicitly — a suite that quietly skips a gate is worse than one that fails.

## Pull-Reflect Maintenance

`openai/codex-plugin-cc` is the upstream semantic source. The mirrors under `ref/` are **not committed** — clone them on demand:

```bash
.claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap   # first run
.claude/skills/pull-reflect/scripts/check-drift.sh               # thereafter
```

Exit `0` means the check ran (printing `no drift` or a summary); exit `2` means **cannot check** — a mirror is missing or is not a git clone, so nothing was verified. A missing mirror never reads as all-clear.

When upstream moves, triage each change as **Port** (relevant to Hermes), **Skip** (Claude Code-specific), or **Adapt** (relevant but needs translation), and record the decision in `docs/drift-log.md`. Every file in `commands/` carries an `Upstream:` line, and prompt placeholders and schema field names are deliberately byte-identical to upstream, so these diffs stay meaningful. Never edit anything under `ref/`.

## License and Attribution

Licensed under the Apache License 2.0. Adapted from [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), Copyright OpenAI, retaining attribution for the upstream command, prompt, and schema design. See `NOTICE`.
