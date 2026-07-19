#!/usr/bin/env bash
# Deterministic drift detector for the pull-reflect loop. No LLM involved.
# Pulls the upstream mirrors; if either moved, prints a drift summary.
# Distinguishes three outcomes so a broken setup can never look like "all clear":
#   exit 0 + "no drift"        -> checked successfully, nothing changed
#   exit 0 + "UPSTREAM DRIFT"  -> checked successfully, something changed
#   exit 2 + "CANNOT CHECK"    -> mirror missing or not a clone; nothing was verified
#
# Usage: check-drift.sh [--notify [target]]   (target default: telegram)
#        check-drift.sh --bootstrap           (clone missing mirrors, then check)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NOTIFY=0; TARGET="telegram"; BOOTSTRAP=0
case "${1:-}" in
  --notify) NOTIFY=1; TARGET="${2:-telegram}" ;;
  --bootstrap) BOOTSTRAP=1 ;;
esac

# mirror name -> upstream URL
mirror_url() {
  case "$1" in
    codex-plugin-cc) printf 'https://github.com/openai/codex-plugin-cc.git' ;;
    hermes-agent)    printf 'https://github.com/NousResearch/hermes-agent.git' ;;
    *) return 1 ;;
  esac
}

drift=""; unchecked=""

for mirror in codex-plugin-cc hermes-agent; do
  dir="$ROOT/ref/$mirror"
  url="$(mirror_url "$mirror")"

  if [ ! -d "$dir/.git" ]; then
    if [ "$BOOTSTRAP" = "1" ]; then
      echo "bootstrapping ref/$mirror from $url ..."
      rm -rf "$dir"
      if git clone --depth 50 --quiet "$url" "$dir"; then
        echo "  cloned ref/$mirror"
      else
        unchecked+="ref/$mirror: clone failed ($url)"$'\n'
        continue
      fi
    else
      if [ -d "$dir" ]; then
        unchecked+="ref/$mirror: present but NOT a git clone — cannot detect drift"$'\n'
      else
        unchecked+="ref/$mirror: missing — cannot detect drift"$'\n'
      fi
      continue
    fi
  fi

  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || {
    unchecked+="ref/$mirror: rev-parse failed"$'\n'; continue; }
  if ! git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
    unchecked+="ref/$mirror: pull failed (offline, or local edits — ref/ must stay pristine)"$'\n'
    continue
  fi
  after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"

  if [ "$before" != "$after" ]; then
    files="$(git -C "$dir" diff --stat "$before..$after" | tail -1)"
    drift+="ref/$mirror: ${before:0:8}..${after:0:8} ($files)"$'\n'
  fi
done

status=0
if [ -n "$unchecked" ]; then
  echo "CANNOT CHECK (nothing was verified for these):"
  printf '%s' "$unchecked"
  echo "Run: $0 --bootstrap   to clone the mirrors."
  status=2
fi

if [ -n "$drift" ]; then
  echo "UPSTREAM DRIFT DETECTED:"
  printf '%s' "$drift"
  echo "Run the pull-reflect skill to triage (Port/Skip/Adapt) and update docs/drift-log.md."
elif [ -z "$unchecked" ]; then
  echo "no drift"
fi

if [ "$NOTIFY" = "1" ] && [ -n "$drift$unchecked" ] && command -v hermes >/dev/null 2>&1; then
  hermes send -q -t "$TARGET" -s "codex-plugin-hermes: upstream check" \
    "${drift}${unchecked}Run pull-reflect in the repo to triage." || true
fi

exit "$status"
