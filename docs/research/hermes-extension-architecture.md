# Hermes Agent Extension Architecture — Research Report

> Produced 2026-07-19 from `ref/hermes-agent` (slimmed mirror; `tools/` package absent — contracts taken from AGENTS.md + registration surfaces). Verified against the live `~/.hermes` install (hermes CLI with `plugins/skills/hooks/cron/send`).

## 1. Plugin system (formal, YAML manifest)

- Core: `hermes_cli/plugins.py`. Each plugin dir = `plugin.yaml` + `__init__.py` with top-level `register(ctx)`.
- `plugin.yaml` fields: `name, version, description, author, requires_env, provides_tools, provides_hooks, kind (standalone|backend|exclusive|platform|model-provider), platforms, hooks`.
- Discovery order (later overrides): bundled `<repo>/plugins/` → user `~/.hermes/plugins/<name>/` → project `./.hermes/plugins/` (needs `HERMES_ENABLE_PROJECT_PLUGINS`) → pip entry-points `hermes_agent.plugins`.
- **Opt-in**: loads only if listed in `plugins.enabled` in config.yaml. Manage with `hermes plugins enable/disable/list`; install from git with `hermes plugins install <repo>`.
- Best in-tree template: `plugins/disk-cleanup/` (manifest + register() wiring 2 hooks + 1 slash command).
- Hard rule (AGENTS.md): plugins never edit core files; extend only via ctx surface.

### PluginContext surface (what register(ctx) can do)
- `ctx.register_command(name, handler, description="", args_hint="")` — in-session slash command; handler `fn(raw_args: str) -> str|None`; **return string becomes the reply** (does NOT re-enter agent loop).
- `ctx.register_tool(name, toolset, schema, handler, ...)` — handler must return JSON string.
- `ctx.register_hook(hook_name, callback)` — see hooks below.
- `ctx.register_skill(name, path, description)` — namespaced `plugin:name`.
- `ctx.register_cli_command(...)` — `hermes <name>` terminal subcommand.
- `ctx.inject_message(content, role="user")` — push a message into live conversation (CLI mode).
- `ctx.dispatch_tool(tool_name, args)` — call registry tools (e.g. `delegate_task`) from a command handler.
- `ctx.llm` — host LLM facade.

## 2. Slash commands — three sources

1. Built-ins: `CommandDef` registry in `hermes_cli/commands.py`; gateway handlers in `gateway/slash_commands.py`.
2. Plugin commands: `ctx.register_command` (reply-only). Collisions with built-ins rejected. Dispatched in `gateway/run.py` (~11128).
3. Skill commands: every SKILL.md auto-registers `/skill-name`, which **rewrites `event.text`** with the skill invocation payload and dispatches as a normal agent turn — this is how a command injects a prompt into the agent loop (`agent/skill_commands.py:_build_skill_message`).

Slack/Matrix use `!` prefix. `args_hint` surfaces in native pickers.

## 3. Hooks — two systems

**(A) Plugin lifecycle hooks** (in-process Python, `ctx.register_hook`), VALID_HOOKS include:
`pre_tool_call, post_tool_call, transform_*, pre_llm_call, post_llm_call, pre_verify, on_session_start, on_session_end, on_session_finalize, on_session_reset, subagent_start, subagent_stop, pre_gateway_dispatch, pre_approval_request, post_approval_response, kanban_*`.
- **`pre_verify` accepts a Claude-Code-style `{"decision":"block","reason":...}` return** (or `{"action":"continue","message":...}`) — this is the native Stop-review-gate analog.
- Registration docs: `hermes_cli/plugins.py:135-215`.

**(B) Gateway file hooks** (`gateway/hooks.py`): dirs under `~/.hermes/hooks/<name>/` with `HOOK.yaml` (`{name, description, events}`) + `handler.py` (`def handle(event_type, context)`). Events: `gateway:startup, session:start, session:end, session:reset, agent:start, agent:step, agent:end, command:*`. Errors logged, never block.

**(C) Shell hooks in config.yaml** (live install): `hooks:` → event → `[{command, matcher, timeout}]`, consent via `~/.hermes/shell-hooks-allowlist.json`, managed by `hermes hooks`.

## 4. Skills

- SKILL.md + YAML frontmatter (Anthropic style). Locations: bundled `skills/<category>/`, user `~/.hermes/skills/`, config `skills.external_dirs`, plugin `ctx.register_skill`.
- Frontmatter hardline: `description` ≤60 chars, one sentence, ends with period. `platforms:`, `metadata.hermes.{tags,category,related_skills,config}`.
- Supporting dirs: `scripts/ references/ templates/ assets/` (listed to the agent with `skill_view` mappings).
- Tests at `tests/skills/test_<skill>_skill.py` (stdlib+pytest+mock, no network).

## 5. Tools / delegation / notifications

- `delegate_task`: spawns subagent; `background=true` → returns delegation id, result re-enters async. Batch `tasks:[...]` parallel (cap `delegation.max_concurrent_children`=3). Roles leaf/orchestrator.
- Durable background work: `terminal(background=True, notify_on_complete=True)` or `cronjob` (survives restart).
- **`hermes send`** (`hermes_cli/send_cmd.py`): `hermes send [-t platform[:chat_id[:thread_id]]|platform:#channel] [msg] [-f file] [-s subject] [-q] [--json] [--list]`. No gateway needed for token platforms (Telegram/Discord/Slack/Signal). `MEDIA:<path>` for attachments. Exit 0/1.

## 6. Sessions

- SQLite (`hermes_state.py`): `sessions(id, source, started_at)` + `messages(session_id, role, content, timestamp)`, FTS-indexed, `parent_session_id` chains.
- Export: `hermes_cli/session_export.py` → jsonl / markdown / full-markdown / user-prompts formats; `hermes dump`, backup/import subcommands.

## 7. Config + existing Codex integration

- `mcp_servers:` in config.yaml (stdio `{command,args,env}` or HTTP `{url,headers}`).
- `plugins.enabled` / `plugins.disabled` / `plugins.entries.<id>.*`.
- **Codex is first-class in Hermes**: `/codex-runtime` toggles `model.openai_runtime` between `auto` and `codex_app_server` (`hermes_cli/codex_runtime_switch.py`); `agent/codex_runtime.py` runs turns through a codex subprocess and exposes Hermes tools to it via internal MCP server **`hermes-tools`**; provider `openai-codex`; models in `hermes_cli/codex_models.py`.
- State discipline: use `get_hermes_home()`, never hardcode `~/.hermes`.

## 8. Conventions

- AGENTS.md: "core is a narrow waist" — extend via plugins/skills/CLI. Prompt caching is sacred.
- Tests: `scripts/run_tests.sh` (per-file isolation), ruff + ty.
- Curator manages agent-created skills lifecycle; never deletes (archives).

## Cheat-sheet: Claude Code → Hermes

| Claude Code | Hermes |
|---|---|
| plugin.json manifest | `plugin.yaml` + `__init__.py:register(ctx)` |
| commands/*.md (prompt-executing) | `ctx.register_command` (reply-only) or SKILL.md command (prompt-injecting) |
| hooks.json SessionStart/End | `ctx.register_hook("on_session_start"/"on_session_end")` |
| Stop hook `{"decision":"block"}` | `ctx.register_hook("pre_verify")` — same return shape supported |
| Agent tool (subagents) | `delegate_task` tool / `ctx.dispatch_tool` |
| Bash(run_in_background) | `terminal(background=True, notify_on_complete=True)` |
| no notifications | `hermes send -t telegram[:chat:thread]` |
| ~/.claude/projects JSONL | SQLite sessions + `session_export` jsonl |
