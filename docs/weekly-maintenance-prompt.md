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

STEP 0 — Get the sources. Run:
    .claude/skills/pull-reflect/scripts/check-drift.sh --bootstrap
This clones BOTH upstream repos into ref/ (gitignored, never committed):
    ref/codex-plugin-cc  — openai/codex-plugin-cc, the semantics we port FROM
    ref/hermes-agent     — NousResearch/hermes-agent, the platform we port TO (~236 MB)

You need both. Porting a change means answering two questions — "what did upstream do?"
and "what is the Hermes equivalent?" — and the second is answered by READING
ref/hermes-agent SOURCE. Do not guess at Hermes APIs and do not trust any prose summary
over the source:
    hermes_cli/plugins.py   — plugin.yaml manifest fields, the register(ctx) surface,
                              VALID_HOOKS, and each hook's exact kwargs and return contract
    hermes_cli/plugins_cmd.py — install/enable mechanics
    hermes_cli/send_cmd.py  — `hermes send` notification CLI
    tools/                  — delegate_task, terminal, and the rest of the tool surface
    AGENTS.md               — Hermes' own plugin authoring rules and constraints
The files under docs/research/ are navigational maps written earlier; they are useful for
finding your way around, but where they disagree with the source, THE SOURCE WINS — fix
the doc and note it in docs/known_issues.md.

If the bootstrap reports CANNOT CHECK (exit 2), you have no network. Report that plainly,
skip steps 2 and 3, and still run step 1.

STEP 1 — Health gates. Run:
    bash tests/acceptance.sh
    shellcheck -S warning scripts/codex-companion.sh scripts/doctor.sh .claude/skills/pull-reflect/scripts/check-drift.sh
    python3 -m py_compile __init__.py
Install shellcheck if absent (apt-get install -y shellcheck). Expect "0 failed".
If anything FAILS, that is this week's job: fix it, and skip step 2. Report what broke.

STEP 2 — Upstream drift. Re-run the detector (the mirrors are cloned now):
    .claude/skills/pull-reflect/scripts/check-drift.sh
  - Exit 0 + "no drift"  -> nothing changed upstream. Go to step 4.
  - Exit 0 + drift summary -> go to step 3.
  - Exit 2 "CANNOT CHECK" -> nothing was verified. Never report this as "no drift".
Drift in ref/hermes-agent matters as much as drift in ref/codex-plugin-cc: if a hook's
kwargs, the manifest fields, or the register(ctx) surface changed, this plugin may be
silently broken against current Hermes even though upstream codex-plugin-cc never moved.
Check that our pre_verify and on_session_end hooks still match their contracts in
hermes_cli/plugins.py, and that plugin.yaml still uses fields the loader reads.

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
