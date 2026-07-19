#!/usr/bin/env bash
# Acceptance contract for codex-plugin-hermes v0.1.
# Authored by the manager; the implementation must make this pass WITHOUT editing this file.
# Usage: tests/acceptance.sh   (add RUN_LIVE=1 for the live codex smoke test)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANION="$ROOT/scripts/codex-companion.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

# Isolated state for every companion invocation
export CODEX_COMPANION_STATE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CODEX_COMPANION_STATE_ROOT"' EXIT

# ---------- 1. Structure ----------
for f in plugin.yaml __init__.py scripts/codex-companion.sh \
         prompts/adversarial-review.md prompts/stop-review-gate.md \
         schemas/review-output.schema.json skills/codex-cli-runtime/SKILL.md \
         commands/review.md commands/adversarial-review.md commands/rescue.md \
         commands/transfer.md commands/status.md commands/result.md \
         commands/cancel.md commands/setup.md; do
  check "exists: $f" test -f "$ROOT/$f"
done
check "companion is executable" test -x "$COMPANION"
# ref/ holds upstream mirrors: never vendored (only the README is ours), never edited in place.
check "ref/: only README.md is tracked (mirrors not vendored)" bash -c '
  cd "'"$ROOT"'" && [ "$(git ls-files ref/)" = "ref/README.md" ]'
check "ref/: no in-place modifications to mirror contents" bash -c '
  cd "'"$ROOT"'" && ! git status --porcelain -- ref/ | grep -qE "^( M|M |MM) ref/(codex-plugin-cc|hermes-agent)/"'

# ---------- 2. Static quality ----------
check "bash -n companion" bash -n "$COMPANION"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck companion" shellcheck -S warning "$COMPANION"
else
  SKIPPED="${SKIPPED:-}shellcheck (not installed) "
  printf 'SKIP shellcheck companion — shellcheck not installed\n'
fi
check "py_compile __init__.py" python3 -m py_compile "$ROOT/__init__.py"
check "__init__.py defines register(ctx)" grep -qE '^def register\(ctx' "$ROOT/__init__.py"
check "__init__.py stdlib-only imports" bash -c '! grep -E "^(import|from) (yaml|requests|httpx|pydantic)" "'"$ROOT"'/__init__.py"'
check "plugin.yaml parses w/ required keys" python3 - "$ROOT/plugin.yaml" <<'EOF'
import sys, re
raw = open(sys.argv[1]).read()
for key in ("name:", "version:", "description:", "kind:", "provides_hooks:"):
    assert re.search(rf"^{key}", raw, re.M), key
assert re.search(r"^name:\s*codex\s*$", raw, re.M)
EOF
check "schema is valid JSON with verdict enum" python3 - "$ROOT/schemas/review-output.schema.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert "approve" in json.dumps(s) and "needs-attention" in json.dumps(s)
EOF

# ---------- 3. Prompts ----------
check "adversarial prompt placeholders" bash -c 'for t in TARGET_LABEL USER_FOCUS REVIEW_COLLECTION_GUIDANCE REVIEW_INPUT; do grep -q "{{$t}}" "'"$ROOT"'/prompts/adversarial-review.md" || exit 1; done'
check "stop-gate prompt placeholder + contract" bash -c 'grep -q "{{CLAUDE_RESPONSE_BLOCK}}" "'"$ROOT"'/prompts/stop-review-gate.md" && grep -q "ALLOW:" "'"$ROOT"'/prompts/stop-review-gate.md" && grep -q "BLOCK:" "'"$ROOT"'/prompts/stop-review-gate.md"'

# ---------- 4. Skill hardline ----------
check "SKILL.md description <=60 chars, ends with period" python3 - "$ROOT/skills/codex-cli-runtime/SKILL.md" <<'EOF'
import sys, re
raw = open(sys.argv[1]).read()
m = re.search(r"^---\n(.*?)\n---", raw, re.S)
assert m, "no frontmatter"
fm = m.group(1)
dm = re.search(r"^description:[ \t]*(.*)$", fm, re.M)   # no DOTALL: stay on one line
assert dm, "no description"
desc = dm.group(1).strip()
if desc in ("|", ">", "|-", ">-", "|+", ">+"):          # block scalar: join indented lines
    parts = []
    for line in fm[dm.end():].split("\n"):
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
            parts.append(line.strip())
        else:
            break
    desc = " ".join(parts)
assert len(desc) <= 60, f"{len(desc)} chars: {desc!r}"
assert desc.endswith("."), f"no trailing period: {desc!r}"
EOF

# ---------- 5. Companion offline behavior ----------
check "help exits 0" "$COMPANION" help
check "help lists all subcommands" bash -c 'h="$("'"$COMPANION"'" help 2>&1)"; for s in setup review adversarial-review task transfer status result task-resume-candidate cancel; do grep -q "$s" <<<"$h" || exit 1; done'
check "unknown subcommand exits nonzero" bash -c '! "'"$COMPANION"'" no-such-subcommand 2>/dev/null'
check "status with no jobs exits 0" "$COMPANION" status
check "status --json is valid JSON" bash -c '"'"$COMPANION"'" status --json | python3 -m json.tool >/dev/null'
check "setup --json shape" bash -c '"'"$COMPANION"'" setup --json | python3 -c "
import json,sys
d = json.load(sys.stdin)
for k in (\"codex_available\",\"authenticated\",\"jq_available\",\"hermes_send_available\",\"state_dir\",\"review_gate\"):
    assert k in d, k
"'
check "state dir created under override root" bash -c 'ls "$CODEX_COMPANION_STATE_ROOT" | grep -q .'
check "enable-review-gate persists" bash -c '"'"$COMPANION"'" setup --enable-review-gate >/dev/null 2>&1; "'"$COMPANION"'" setup --json | python3 -c "import json,sys; assert json.load(sys.stdin)[\"review_gate\"] is True"'
check "disable-review-gate persists" bash -c '"'"$COMPANION"'" setup --disable-review-gate >/dev/null 2>&1; "'"$COMPANION"'" setup --json | python3 -c "import json,sys; assert json.load(sys.stdin)[\"review_gate\"] is False"'
check "resume-candidate --json shape (empty)" bash -c '"'"$COMPANION"'" task-resume-candidate --json | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d[\"available\"] is False and d[\"candidate\"] is None
"'
check "result with no jobs is graceful" bash -c 'out="$("'"$COMPANION"'" result 2>&1)"; test -n "$out"'
check "cancel with no jobs is graceful" bash -c 'out="$("'"$COMPANION"'" cancel 2>&1)"; test -n "$out"'
check "review rejects focus text" bash -c '! "'"$COMPANION"'" review "make sure the auth is fine" 2>/dev/null'

# ---------- 6. Dependencies + portability ----------
check "exists: dependencies.yaml" test -f "$ROOT/dependencies.yaml"
check "exists: scripts/doctor.sh" test -f "$ROOT/scripts/doctor.sh"
check "doctor.sh is executable" test -x "$ROOT/scripts/doctor.sh"
check "bash -n doctor.sh" bash -n "$ROOT/scripts/doctor.sh"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck doctor.sh" shellcheck -S warning "$ROOT/scripts/doctor.sh"
fi
check "dependencies.yaml declares required runtime deps" python3 - "$ROOT/dependencies.yaml" <<'EOF'
import sys, re
raw = open(sys.argv[1]).read()
for dep in ("codex", "jq", "git", "bash"):
    assert re.search(rf"\b{dep}\b", raw), f"missing dependency declaration: {dep}"
assert "required" in raw and "optional" in raw, "must separate required vs optional deps"
EOF
check "doctor --json lists deps with present flags" bash -c '"'"$ROOT"'/scripts/doctor.sh" --json | python3 -c "
import json,sys
d = json.load(sys.stdin)
deps = d[\"dependencies\"] if isinstance(d, dict) and \"dependencies\" in d else d
names = {x[\"name\"] for x in deps}
for req in (\"codex\",\"jq\",\"git\"):
    assert req in names, req
for x in deps:
    assert isinstance(x[\"present\"], bool), x
"'
# doctor exits non-zero when a required dep is genuinely absent, so this check is only
# meaningful where the codex CLI exists (it won't in a cloud container). Skip loudly.
if command -v codex >/dev/null 2>&1; then
  check "doctor exits 0 when required deps present" "$ROOT/scripts/doctor.sh"
else
  SKIPPED="${SKIPPED:-}doctor-exit-0 (codex CLI absent) "
  printf 'SKIP doctor exits 0 — codex CLI not installed in this environment\n'
fi
# doctor must still FAIL when a required dep is missing, everywhere.
check "doctor exits non-zero when a required dep is missing" bash -c '
  d=$(mktemp -d); for b in bash git awk sed date mktemp head tail tr wc cut basename dirname \
      find grep mv rm mkdir cat nohup sha256sum; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$d/$b"
  done
  ! PATH="$d" "'"$ROOT"'/scripts/doctor.sh" >/dev/null 2>&1'
# Portability: a detached worker must not depend on setsid alone (macOS has no setsid).
check "worker spawn has non-setsid fallback" bash -c '
  grep -q "setsid" "'"$COMPANION"'" || exit 0            # no setsid at all is fine
  grep -qE "command -v setsid|has_setsid|SETSID" "'"$COMPANION"'"   # must be guarded
'
check "README documents requirements incl. jq and git" bash -c 'grep -qi "jq" "'"$ROOT"'/README.md" && grep -qiE "^- .*[Gg]it|[Gg]it " "'"$ROOT"'/README.md"'

# ---------- 7. Optional live smoke ----------
if [ "${RUN_LIVE:-0}" = "1" ]; then
  check "live: setup reports codex available" bash -c '"'"$COMPANION"'" setup --json | python3 -c "import json,sys; assert json.load(sys.stdin)[\"codex_available\"] is True"'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ -n "${SKIPPED:-}" ] && printf 'SKIPPED CHECKS (coverage gap): %s\n' "$SKIPPED"
exit $((FAIL > 0))
