# Changelog

## 2026-07-19
- Project scaffold + PRD (pre-existing).
- Session: deep research on Hermes extension architecture (ref/hermes-agent) + codex-plugin-cc semantics (ref/codex-plugin-cc).
- Verified live environment: codex-cli 0.144.6, hermes CLI with `plugins/skills/hooks/cron/send` subsystems at ~/.hermes.
- Research complete → `docs/research/codex-plugin-cc-semantics.md` + `docs/research/hermes-extension-architecture.md`.
- Wrote `SPEC.md` (implementation contract for Codex) + `tests/acceptance.sh` (verification contract, manager-owned).
- **Codex round 1** (delegated via rescue): implemented plugin.yaml, __init__.py (8 commands + 2 hooks), 8 command docs, scripts/codex-companion.sh (~864 lines), both prompts, schema, skill, README. Acceptance 39/39. Codex correctly flagged a manager error in SPEC §4 (`--skip-git-repo-check=false` — that flag takes no value) and omitted it.
- **Manager verification**: prompts/schema confirmed faithful to upstream (schema byte-identical; full placeholder + XML-block parity; only host references adapted). Live end-to-end against real Codex CLI: foreground task, background job + detached worker, result, status table, resume-with-retained-context, native review (explicit + auto mode), setup. `register(ctx)` wires 8 commands + `pre_verify`/`on_session_end`; gate is fail-open and hooks never raise. Hermes discovers the plugin (`codex 0.1.0`).
- **Codex round 2** (defect list): quoted `REVIEW_MODE` assignments (shellcheck SC2209), added LICENSE + NOTICE (README claimed Apache-2.0 with no license file), corrected README install instructions (`hermes plugins install` takes a Git URL/`owner/repo`, never a local path). Final: **40 passed, 0 failed**, shellcheck clean.
- Installed shellcheck 0.11.0 to `~/.local/bin` — the gate had been silently skipping; acceptance now reports skipped checks loudly.
- Key mapping decisions: Hermes-native plugin (`plugin.yaml` + `register(ctx)`), `pre_verify` hook = stop review gate (fail-open), `codex exec review --uncommitted|--base` = native review, background jobs via detached worker + `hermes send` Telegram notify.
- **Codex round 4**: condensed `dependencies.yaml` from 27 entries to 9 (5 required: bash, codex, jq, git, posix-userland) while `doctor.sh` still verifies all 18 underlying binaries; missing-dep probes correctly exit 1.
- **Published** 2026-07-19: committed (96 files) and flipped `ricalanis/codex-plugin-hermes` private → public. Verified from a fresh clone: 51/51 acceptance, doctor exit 0, `ref/` reduced to README only.
- README rewritten for autonomous install after researching Hermes install mechanics. Three findings that would each have broken an unattended install: `--enable` is mandatory (non-TTY installs land **disabled** silently), the installed plugin is named `codex` not the repo name (manifest `name:` drives the install dir and `plugins.enabled` key), and `manifest_version: 1` was missing. Added `after-install.md`, a documented-but-unused Hermes convention rendered post-install.
- **History cleaned + install prompt added** 2026-07-19: stripped the vendored upstream from all commits and force-pushed; added an "Install by asking Hermes" prompt to the README that encodes the three silent-failure modes (`--enable` required, plugin is named `codex`, gateway restart).
