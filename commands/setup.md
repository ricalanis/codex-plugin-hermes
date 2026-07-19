# `/codex-setup`

**Description:** Check Codex CLI readiness and configure the optional stop-time review gate.

**Arguments:** `[--enable-review-gate|--disable-review-gate] [--json]`

## Behavior

- Checks the Codex binary and version, authentication, `jq`, `hermes send`, and workspace-state access.
- Points to `scripts/doctor.sh` for the complete required, optional, and development dependency report.
- When Codex is missing, prints the `npm install -g @openai/codex` command. When it is unauthenticated, prints the `codex login` command.
- Gate flags persist the workspace's fail-open review-gate setting. Without a flag, setup only reports current state.

## Examples

```text
/codex-setup
/codex-setup --enable-review-gate
/codex-setup --disable-review-gate --json
```

Upstream: ref/codex-plugin-cc/plugins/codex/commands/setup.md
