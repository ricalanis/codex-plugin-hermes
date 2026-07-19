---
name: supervise-codex
description: Delegate implementation work on this repo to Codex and verify it contract-first, manager-style.
---

# Supervise Codex: delegation workflow for this repo

Roles are fixed: **Codex = senior developer** (writes the code), **Claude = senior technical manager** (specs, delegates, verifies). Do not implement plugin code yourself unless Codex is unavailable after two attempts.

## Before delegating

1. The work must have a written contract. Small change → a precise brief with acceptance criteria inline. Structural change → update `SPEC.md` first.
2. Verification must be cheap: extend `tests/acceptance.sh` (or state the exact commands to run) BEFORE delegation. Never plan to re-read Codex's diff line-by-line as the primary check — verification cost scales with the spec, not the solution.

## The brief (template)

Send via the `codex:codex-rescue` agent (or `/codex:rescue` if user-driven), one task per brief:

- Working dir: the repository root (absolute path).
- Read order: `SPEC.md` (fixed decisions in §0), `tests/acceptance.sh`, relevant `docs/research/*`, relevant `ref/` sources.
- Hard rules: never edit `tests/acceptance.sh`, `SPEC.md`, `PRD.md`, `docs/`, or anything under `ref/`; spec/test conflict → implement to the test and flag it; no git commits.
- Definition of done: `bash tests/acceptance.sh` prints `0 failed`; shellcheck clean at `-S warning`; `python3 -m py_compile __init__.py` clean.
- Required final report: files touched, last lines of the acceptance tally, judgment calls made.

Note: the rescue channel may return "started in the background as `<job-id>`" — poll with the companion's `status <job-id>` and fetch output with `result <job-id>` rather than assuming completion.

## After Codex reports

1. Run `bash tests/acceptance.sh` yourself — trust the tally, not the narrative.
2. Spot-check only judgment calls Codex flagged, plus anything user-facing (README wording, command replies).
3. Failures → send back a defect list (what fails + expected behavior), not fixes. Codex fixes its own code.
4. Green → update `docs/changelog.md`; record recurring mistakes in `docs/known_issues.md`; commit only when the user asks.

## Escalation

Two failed round-trips on the same defect → stop delegating that item; either tighten the contract (usually the real bug) or implement it directly and note why in `docs/decisions.md`.
