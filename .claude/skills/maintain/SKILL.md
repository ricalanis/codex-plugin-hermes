---
name: maintain
description: Health-check, repair, and routine upkeep for the codex-plugin-hermes repo.
---

# Maintain: routine upkeep and health checks

Run this for "is the repo healthy?", "something broke", "update the deps", or scheduled upkeep. For upstream changes specifically, use the `pull-reflect` skill instead — this skill covers everything else.

## 1. Health check (always start here)

```bash
export PATH="$HOME/.local/bin:$PATH"
scripts/doctor.sh                                   # dependency preflight
bash tests/acceptance.sh                            # full contract
shellcheck -S warning scripts/codex-companion.sh scripts/doctor.sh
python3 -m py_compile __init__.py
```

Read the tally, not the narrative. Two rules:

- A `SKIPPED CHECKS (coverage gap)` line means a gate did not run. That is **not** a pass — install the missing tool and re-run. A green suite that quietly skips checks is worse than a red one.
- If a check fails, reproduce it in isolation against a known-good input **before** blaming the implementation. A contract check has been wrong before (see `docs/known_issues.md`).

## 2. Live smoke test (when behavior is suspect)

The contract is offline-only; these exercise the real Codex CLI. Always use a scratch state root so real jobs are untouched:

```bash
export CODEX_COMPANION_STATE_ROOT=$(mktemp -d)
./scripts/codex-companion.sh setup
./scripts/codex-companion.sh task --fresh "Reply with exactly the word PONG and nothing else."
./scripts/codex-companion.sh task --background --fresh "Reply with exactly: ALPHA"
./scripts/codex-companion.sh status          # worker should reach completed (~15s)
./scripts/codex-companion.sh task-resume-candidate --json
```

Never smoke-test while an agent is still editing `scripts/codex-companion.sh` — bash reads scripts incrementally, so a concurrent edit produces phantom syntax errors that look like real defects.

## 3. Hermes integration check

```bash
hermes plugins list | grep -A2 '│ codex'    # should show codex + version
```

To verify registration without touching `~/.hermes/config.yaml`, exec `__init__.py` with a stub `ctx` that records `register_command` / `register_hook` calls, then assert 8 commands and both hooks (`pre_verify`, `on_session_end`). The stop gate must return `None` instantly when disabled and must never raise — it is deliberately **fail-open** so a plugin error cannot trap a Hermes session.

## 4. Job-state upkeep

State lives under `${HERMES_HOME:-~/.hermes}/codex-companion/<workspace-slug>`. Per-job files are the source of truth; `state.json` is a rebuilt index capped at 50 jobs.

- Stuck job: `./scripts/codex-companion.sh cancel <job-id>`.
- Orphaned worker (parent died, job stuck `running`): confirm with `ps -p <pid>` from the job JSON before killing anything.
- Safe reset for a workspace: delete its directory under the state root. Only job history is lost.

## 5. Dependency updates

`dependencies.yaml` is the declaration; `scripts/doctor.sh` enforces it. Keep them in sync — if you add a binary to the companion script, declare it in both, and add a contract check.

After a Codex CLI upgrade, re-verify the flags the companion depends on (`codex exec --json`, `-o`, `exec review --uncommitted|--base`, `exec resume`). A past spec error assumed `--skip-git-repo-check=false`, which takes no value — verify flags against `--help`, never from memory.

## 6. Close the loop

Update `docs/changelog.md` with what changed, `docs/known_issues.md` with any mistake worth not repeating (cause + how to avoid), and `docs/decisions.md` for process/architecture calls. Commit only when the user asks.
