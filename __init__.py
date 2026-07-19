"""Hermes plugin registration for the Codex companion."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Callable, Optional


LOGGER = logging.getLogger(__name__)
PLUGIN_ROOT = Path(__file__).resolve().parent
COMPANION = PLUGIN_ROOT / "scripts" / "codex-companion.sh"

COMMANDS = {
    "codex-review": (
        "review",
        "Run a Codex code review against local git state.",
        "[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch]",
        1800,
    ),
    "codex-adversarial-review": (
        "adversarial-review",
        "Challenge the implementation approach with Codex.",
        "[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch] [focus ...]",
        1800,
    ),
    "codex-rescue": (
        "task",
        "Delegate investigation or rescue work to Codex.",
        "[--background|--wait] [--resume|--fresh] [--model <model|spark>] [--effort <none|minimal|low|medium|high|xhigh>] [what Codex should investigate, solve, or continue]",
        1800,
    ),
    "codex-transfer": (
        "transfer",
        "Transfer a Hermes export into a Codex thread.",
        "[--source <claude-jsonl>]",
        60,
    ),
    "codex-status": (
        "status",
        "Show active and recent Codex jobs.",
        "[job-id] [--wait] [--timeout-ms <ms>] [--all]",
        60,
    ),
    "codex-result": (
        "result",
        "Show a finished Codex job result.",
        "[job-id]",
        60,
    ),
    "codex-cancel": (
        "cancel",
        "Cancel an active Codex job.",
        "[job-id]",
        60,
    ),
    "codex-setup": (
        "setup",
        "Check Codex readiness and configure the review gate.",
        "[--enable-review-gate|--disable-review-gate]",
        60,
    ),
}


def _run(subcommand: str, raw_args: str, timeout: int) -> str:
    """Run one companion command and render its reply-only result."""
    try:
        result = subprocess.run(
            [str(COMPANION), subcommand, raw_args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return f"Codex command timed out after {timeout} seconds."
    except OSError as exc:
        return f"Unable to run the Codex companion: {exc}"

    output = result.stdout
    if result.returncode and result.stderr:
        output += ("\n" if output and not output.endswith("\n") else "") + result.stderr
    return output.rstrip("\n")


def _handler(subcommand: str, timeout: int) -> Callable[[str], str]:
    def handle(raw_args: str) -> str:
        return _run(subcommand, raw_args, timeout)

    return handle


def _workspace_root() -> Path:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip()).resolve()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return Path.cwd().resolve()


def _state_file() -> Path:
    workspace = _workspace_root()
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", workspace.name).strip("-") or "workspace"
    digest = hashlib.sha256(str(workspace).encode()).hexdigest()[:16]
    configured = os.environ.get("CODEX_COMPANION_STATE_ROOT")
    if configured:
        state_root = Path(configured).expanduser()
    else:
        hermes_home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
        state_root = hermes_home / "codex-companion"
    return state_root / f"{slug}-{digest}" / "state.json"


def _review_gate_enabled() -> bool:
    try:
        state = json.loads(_state_file().read_text(encoding="utf-8"))
        return state.get("config", {}).get("stop_review_gate") is True
    except (OSError, ValueError, TypeError):
        return False


def _on_session_end(**_: Any) -> None:
    try:
        subprocess.run(
            [str(COMPANION), "session-end"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        LOGGER.debug("Codex session-end cleanup failed: %s", exc)


def _pre_verify(final_response: str = "", **_: Any) -> Optional[dict[str, str]]:
    if not _review_gate_enabled():
        return None

    try:
        template = (PLUGIN_ROOT / "prompts" / "stop-review-gate.md").read_text(encoding="utf-8")
        prompt = template.replace("{{CLAUDE_RESPONSE_BLOCK}}", final_response)
        result = subprocess.run(
            [str(COMPANION), "task", "--json", prompt],
            capture_output=True,
            text=True,
            timeout=900,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"exit {result.returncode}")
        payload = json.loads(result.stdout)
        raw_output = str(payload.get("raw_output") or payload.get("output") or "")
        first_line = raw_output.splitlines()[0].strip() if raw_output else ""
        if first_line.startswith("ALLOW:"):
            return None
        if first_line.startswith("BLOCK:"):
            reason = first_line.removeprefix("BLOCK:").strip() or "Codex requested another pass."
            return {"decision": "block", "reason": f"Codex stop gate: {reason}"}
        raise ValueError("missing ALLOW/BLOCK decision")
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError, TypeError, json.JSONDecodeError) as exc:
        LOGGER.warning("Codex stop gate failed open: %s", exc)
        return None


def register(ctx) -> None:
    """Register eight reply-only commands and two lifecycle hooks."""
    for name, (subcommand, description, args_hint, timeout) in COMMANDS.items():
        ctx.register_command(
            name,
            handler=_handler(subcommand, timeout),
            description=description,
            args_hint=args_hint,
        )
    ctx.register_hook("on_session_end", _on_session_end)
    ctx.register_hook("pre_verify", _pre_verify)
