# ref/

Read-only reference projects for `codex-plugin-hermes`. Never edit files here.

## Projects

### codex-plugin-cc
Mirror of https://github.com/openai/codex-plugin-cc
- The original Claude Code plugin we're mirroring for Hermes
- 8 slash commands, app-server broker, review gate, session transfer
- Source of truth for command semantics

### hermes-agent
Mirror of https://github.com/NousResearch/hermes-agent
- Hermes Agent source (slimmed — plugin system, slash commands, hooks, gateway only)
- Reference for plugin architecture: `plugins/*.yaml` manifests, `gateway/slash_commands.py`, hooks system
- How Hermes plugins are structured, how slash commands are registered, how hooks fire

## Update

```bash
cd ref/codex-plugin-cc && git pull origin main
cd ref/hermes-agent && git pull origin main --depth 1
```

The pull-reflect cron job does this automatically and flags drift.