# Weekly maintenance task (Codex Web)

Paste the block below into a Codex Web task against `ricalanis/codex-plugin-hermes`, scheduled weekly. It is written to be safe to run when there is nothing to do — the correct outcome most weeks is "no drift, gates green, no PR opened."

---

## Task prompt

```text
You are the weekly maintainer of codex-plugin-hermes, a Hermes Agent plugin that ports
openai/codex-plugin-cc. Read AGENTS.md first — it defines the contracts you must respect.

ENVIRONMENT
This container does NOT have the `codex` CLI or the `hermes` CLI, and it cannot talk to a
Hermes instance. That is expected. The acceptance contract is offline by design and will
skip exactly one check ("doctor exits 0", needs the codex CLI) while printing a SKIPPED
line. A SKIPPED line here is normal; a FAIL is not.

STEP 1 — Health gates. Run:
    bash tests/acceptance.sh
    shellcheck -S warning scripts/codex-companion.sh scripts/doctor.sh .claude/skills/pull-reflect/scripts/check-drift.sh
    python3 -m py_compile __init__.py
Install shellcheck if absent (apt-get install -y shellcheck). Expect "0 failed".
If anything FAILS, that is this week's job: fix it, and skip step 2. Report what broke.

STEP 2 — Upstream drift. Run:
    .claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap
This clones the upstream mirrors into ref/ (gitignored, never committed).
  - Exit 0 + "no drift"  -> nothing changed upstream. Go to step 4.
  - Exit 0 + drift summary -> go to step 3.
  - Exit 2 "CANNOT CHECK" -> the clone failed, usually no network access in this container.
    Do NOT treat this as "no drift". Report that drift could not be checked and why, then
    go to step 4 and still report the step 1 gate results.

STEP 3 — Triage each changed upstream file. Map it to our port using the table in
.claude/skills/pull-reflect/SKILL.md, then classify:
  - PORT  — semantics changed and applies to Hermes. Implement it.
  - SKIP  — Claude Code-specific (${CLAUDE_PLUGIN_ROOT}, AskUserQuestion, the Agent tool,
            app-server/broker internals, $CLAUDE_ENV_FILE, ~/.claude paths). Record why.
  - ADAPT — relevant but needs Hermes translation (host env vars, notification path, hook
            shape, command naming /codex:x -> /codex-x). Implement the adaptation.
For every PORT or ADAPT, add or tighten a check in tests/acceptance.sh covering the new
behavior, and confirm the new check FAILS before your change and PASSES after. A check
that passes before the change tests nothing.

STEP 4 — Record and report.
Append to docs/drift-log.md: date, upstream commit range, and the per-file decision with a
one-line justification. Append a line to docs/changelog.md summarizing the week.

OPEN A PULL REQUEST ONLY IF you changed files. If there was no drift and the gates were
green, do not open a PR — reply with a short "no action needed" report instead. Weekly
no-op PRs train people to ignore this task.

HARD RULES
- Never weaken tests/acceptance.sh to make something pass. It only gets stronger. If the
  contract and the code disagree, the contract wins — fix the code, or explain why the
  contract is wrong and change it deliberately.
- Never edit anything under ref/. It is an upstream mirror; git pull only. Never commit
  ref/ contents — only ref/README.md is tracked.
- Keep prompt placeholder tokens ({{TARGET_LABEL}}, {{CLAUDE_RESPONSE_BLOCK}}, etc.) and
  schemas/review-output.schema.json field names byte-identical to upstream. Drift diffing
  depends on that; renaming them breaks future maintenance.
- Do not add CI, deploy steps, or package manifests. This repo is loaded directly by
  Hermes; there is no build or deploy.
- Do not bump the version or edit LICENSE/NOTICE.

REPORT (always, PR or not)
1. Gate results — the acceptance tally, plus any SKIPPED line verbatim.
2. Drift — upstream commit range and per-file Port/Skip/Adapt decisions, or "no drift", or
   "could not check" with the reason.
3. What you changed, and which acceptance checks now cover it.
4. Anything you deliberately did not do, and why.
```

---

## Scheduling

Codex Web → the repository → schedule the task weekly. Enable internet access for the
container, otherwise step 2 will always report `CANNOT CHECK` and only the gates get
verified — still useful, but say so rather than reporting a clean bill of health.

## Why it is shaped this way

- **Gates before drift.** A broken repo is a more urgent problem than a stale one.
- **Silence is the expected output.** Most weeks upstream will not move. A task that opens
  a PR every week gets muted, and then it is worthless when it matters.
- **`CANNOT CHECK` is never `no drift`.** A no-network container that reports "all clear"
  is the exact failure this repo has already been bitten by (see `docs/known_issues.md`).
- **New behavior needs a failing check first.** Otherwise ported code arrives untested and
  the contract slowly stops meaning anything.
