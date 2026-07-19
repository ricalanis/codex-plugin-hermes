# Weekly maintenance task (Codex Web)

Paste the block below into a Codex Web task against `ricalanis/codex-plugin-hermes`, scheduled weekly. It is written to be safe when there is nothing to do — most weeks the correct outcome is "gates green, no drift, no PR opened."

---

## Task prompt

```text
You are the weekly maintainer of codex-plugin-hermes, a Hermes Agent plugin that ports
openai/codex-plugin-cc. Read AGENTS.md first — it defines the contracts you must respect.

ENVIRONMENT
This container has neither the `codex` CLI nor the `hermes` CLI, and cannot reach a Hermes
instance. That is expected and not a failure. The acceptance contract is offline by design;
it will skip exactly one check ("doctor exits 0", which needs the codex CLI) and print a
SKIPPED line. A SKIPPED line is normal here. A FAIL is not.
The ref/ directory is empty on checkout — the upstream mirrors are gitignored and cloned
only when needed (step 3). Drift detection does NOT need them.

STEP 1 — Health gates.
    bash tests/acceptance.sh
    shellcheck -S warning scripts/codex-companion.sh scripts/doctor.sh .claude/skills/pull-reflect/scripts/check-drift.sh
    python3 -m py_compile __init__.py
Install shellcheck if absent: apt-get install -y shellcheck
Expect "0 failed". If anything FAILS, that is this week's job — fix it and skip step 2.

STEP 2 — Upstream drift (cheap: queries the remotes, clones nothing).
    .claude/skills/pull-reflect/scripts/check-drift.sh
It compares the live upstream HEADs against upstream.lock, the commits this repo was last
reconciled against.
  - exit 0, "no drift"           -> upstream has not moved. Go to step 5.
  - exit 0, "UPSTREAM DRIFT"     -> go to step 3.
  - exit 2, "CANNOT CHECK"       -> nothing was verified. Report it plainly, never as
                                    "no drift", and go to step 5.
If the cause is no network (git ls-remote fails, apt/GitHub return 403), say so explicitly
and flag it as a CONFIGURATION PROBLEM NEEDING A HUMAN, not a transient error: the
container needs internet access enabled in the Codex Web environment settings, with
github.com allowed. Until that is fixed this task can only run the gates — half of its
purpose is dead, and a report that merely notes "could not check" every week will be
mistaken for routine. Put it at the TOP of your report, not under "deliberately not done".

STEP 3 — Read the changed source.
    .claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap
This clones both mirrors into ref/ so you can read them:
    ref/codex-plugin-cc  — openai/codex-plugin-cc, the semantics we port FROM
    ref/hermes-agent     — NousResearch/hermes-agent, the platform we port TO (~236 MB)
Porting means answering two questions: "what did upstream change?" and "what is the Hermes
equivalent?" The second is answered by READING ref/hermes-agent source — never by guessing
and never from a prose summary:
    hermes_cli/plugins.py     — manifest fields, the register(ctx) surface, VALID_HOOKS,
                                and each hook's exact kwargs and return contract
    hermes_cli/plugins_cmd.py — install/enable mechanics
    hermes_cli/send_cmd.py    — `hermes send` notification CLI
    tools/                    — delegate_task, terminal, and the rest of the tool surface
    AGENTS.md                 — Hermes' own plugin authoring rules
Files under docs/research/ are navigational maps written earlier. Where they disagree with
the source, THE SOURCE WINS — fix the doc and note it in docs/known_issues.md.

Drift in ref/hermes-agent matters as much as drift in ref/codex-plugin-cc: if a hook's
kwargs, the manifest fields, or the register(ctx) surface changed, this plugin can be
silently broken against current Hermes even though codex-plugin-cc never moved. Verify our
pre_verify and on_session_end hooks still match their contracts in hermes_cli/plugins.py,
and that plugin.yaml still uses fields the loader actually reads.

STEP 4 — Triage each changed file. Map it to our port using the table in
.claude/skills/pull-reflect/SKILL.md, then classify:
  - PORT  — semantics changed and applies to Hermes. Implement it.
  - SKIP  — Claude Code-specific (${CLAUDE_PLUGIN_ROOT}, AskUserQuestion, the Agent tool,
            app-server/broker internals, $CLAUDE_ENV_FILE, ~/.claude paths). Record why.
  - ADAPT — relevant but needs translation (host env vars, notification path, hook shape,
            command naming /codex:x -> /codex-x). Implement the adaptation.
For every PORT or ADAPT, add or tighten a check in tests/acceptance.sh covering the new
behavior, and confirm it FAILS before your change and PASSES after. A check that already
passed before the change tests nothing.

STEP 5 — Record, and close the loop.
If you triaged drift in step 4:
  - Append to docs/drift-log.md: date, upstream commit range, per-file decision, one-line
    justification for each.
  - Run: .claude/skills/pull-reflect/scripts/check-drift.sh --update-lock
    This records the reviewed commits in upstream.lock. WITHOUT IT the same drift is
    reported again every week forever. Only update the lock for drift you actually
    triaged — never to silence a report you did not act on.
  - Append a line to docs/changelog.md.

OPEN A PULL REQUEST ONLY IF you changed files. If the gates were green and there was no
drift, do not open a PR — reply with a short "no action needed" report. Weekly no-op PRs
train people to ignore this task.

HARD RULES
- Never weaken tests/acceptance.sh to make something pass. It only gets stronger. If the
  contract and the code disagree, the contract wins — fix the code, or explain why the
  contract itself is wrong and change it deliberately.
- Never edit anything under ref/. It is an upstream mirror. Never commit ref/ contents —
  only ref/README.md is tracked.
- Keep prompt placeholder tokens ({{TARGET_LABEL}}, {{CLAUDE_RESPONSE_BLOCK}}, etc.) and
  schemas/review-output.schema.json field names byte-identical to upstream. Drift diffing
  depends on it.
- Do not add CI, deploy steps, or package manifests. This repo is loaded directly by
  Hermes; there is no build or deploy.
- Do not bump the version or edit LICENSE/NOTICE.

REPORT (always, PR or not)
1. Gate results — the acceptance tally, plus any SKIPPED line verbatim.
2. Drift — the commit range and per-file Port/Skip/Adapt decisions, or "no drift", or
   "could not check" with the reason.
3. What you changed, which acceptance checks now cover it, and whether upstream.lock moved.
4. Anything you deliberately did not do, and why.
```

---

## Scheduling

In Codex Web, point a task at this repository and schedule it weekly. Enable internet access for the container — without it, step 2 reports `CANNOT CHECK` and only the gates are verified. That is still useful, but the report must say so rather than implying a clean bill of health.

## Why it is shaped this way

- **Gates before drift.** A broken repo is more urgent than a stale one.
- **Drift detection needs no clone.** `upstream.lock` records the commits we reconciled against, so a container with an empty `ref/` can still detect drift by querying the remotes. An earlier design compared a local clone against itself, which in a fresh container meant cloning the latest and always concluding "no drift" — a check that could never fail.
- **The lockfile must be updated only after triage.** It is the memory of what a human or agent actually reviewed. Updating it without triaging silently discards an upstream change.
- **`CANNOT CHECK` is never `no drift`.** A no-network container reporting "all clear" is a failure this repo has already been bitten by twice (see `docs/known_issues.md`).
- **Silence is the expected output.** Most weeks upstream will not move, and the task should say so without opening a PR.
- **New behavior needs a check that failed first.** Otherwise ported code arrives untested and the contract slowly stops meaning anything.
