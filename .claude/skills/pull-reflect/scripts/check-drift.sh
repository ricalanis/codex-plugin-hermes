#!/usr/bin/env bash
# Deterministic upstream drift detector for the pull-reflect loop. No LLM involved.
#
# Drift = the live upstream HEAD differs from the SHA recorded in upstream.lock,
# which is the commit this repo was last reconciled against. The lockfile is
# committed, so this works in an ephemeral container (CI, Codex Web) that has no
# previous clone to compare against — checking out ref/ is NOT required.
#
# Three outcomes, so a broken setup can never look like "all clear":
#   exit 0 + "no drift"       -> checked; upstream matches the lockfile
#   exit 0 + "UPSTREAM DRIFT" -> checked; upstream moved past the lockfile
#   exit 2 + "CANNOT CHECK"   -> nothing was verified (no network, bad lockfile)
#
# Usage:
#   check-drift.sh                 check for drift (cheap: ls-remote, no clone)
#   check-drift.sh --notify [tgt]  also push the result through `hermes send`
#   check-drift.sh --bootstrap     clone/refresh the mirrors under ref/, then check
#   check-drift.sh --update-lock   record current upstream HEADs as reconciled
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LOCK="$ROOT/upstream.lock"
NOTIFY=0; TARGET="telegram"; BOOTSTRAP=0; UPDATE_LOCK=0
case "${1:-}" in
  --notify) NOTIFY=1; TARGET="${2:-telegram}" ;;
  --bootstrap) BOOTSTRAP=1 ;;
  --update-lock) UPDATE_LOCK=1 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac

MIRRORS=(codex-plugin-cc hermes-agent)

mirror_url() {
  case "$1" in
    codex-plugin-cc) printf 'https://github.com/openai/codex-plugin-cc.git' ;;
    hermes-agent)    printf 'https://github.com/NousResearch/hermes-agent.git' ;;
    *) return 1 ;;
  esac
}

locked_sha() { [ -f "$LOCK" ] && awk -v m="$1" '$1==m {print $2}' "$LOCK"; }
remote_sha() { git ls-remote "$(mirror_url "$1")" HEAD 2>/dev/null | cut -f1; }

# --update-lock: record current remote HEADs as reconciled.
if [ "$UPDATE_LOCK" = "1" ]; then
  tmp="$(mktemp)"
  {
    echo "# Upstream commits this repo has been reconciled against."
    echo "# check-drift.sh compares these to the live remote HEADs."
    echo "# Update ONLY after triaging the drift (see .claude/skills/pull-reflect/SKILL.md)."
    for m in "${MIRRORS[@]}"; do
      sha="$(remote_sha "$m")"
      if [ -z "$sha" ]; then
        echo "CANNOT CHECK: no network; lockfile not updated" >&2
        rm -f "$tmp"; exit 2
      fi
      printf '%s %s\n' "$m" "$sha"
    done
  } >"$tmp" || { rm -f "$tmp"; exit 2; }
  mv "$tmp" "$LOCK"
  echo "upstream.lock updated:"; grep -v '^#' "$LOCK"
  exit 0
fi

# --bootstrap: clone or refresh the mirrors so their source can be read.
if [ "$BOOTSTRAP" = "1" ]; then
  for m in "${MIRRORS[@]}"; do
    dir="$ROOT/ref/$m"
    if [ -d "$dir/.git" ]; then
      echo "refreshing ref/$m ..."
      git -C "$dir" fetch --quiet --depth 50 origin 2>/dev/null &&
        git -C "$dir" reset --hard --quiet FETCH_HEAD 2>/dev/null &&
        echo "  refreshed" || echo "  refresh failed (offline?)"
    else
      echo "cloning ref/$m ..."
      rm -rf "$dir"
      git clone --depth 50 --quiet "$(mirror_url "$m")" "$dir" &&
        echo "  cloned" || echo "  clone failed (offline?)"
    fi
  done
fi

drift=""; unchecked=""

if [ ! -f "$LOCK" ]; then
  echo "CANNOT CHECK: $LOCK is missing — nothing to compare against." >&2
  echo "Run: $0 --update-lock   to record the current upstream HEADs." >&2
  exit 2
fi

for m in "${MIRRORS[@]}"; do
  want="$(locked_sha "$m")"
  got="$(remote_sha "$m")"
  if [ -z "$want" ]; then
    unchecked+="ref/$m: no entry in upstream.lock — cannot compare"$'\n'; continue
  fi
  if [ -z "$got" ]; then
    unchecked+="ref/$m: could not reach upstream (offline?) — nothing verified"$'\n'; continue
  fi
  if [ "$want" != "$got" ]; then
    range="${want:0:8}..${got:0:8}"
    detail=""
    # If the mirror is cloned locally we can show what actually changed.
    if [ -d "$ROOT/ref/$m/.git" ] && git -C "$ROOT/ref/$m" cat-file -e "$want^{commit}" 2>/dev/null; then
      detail=" $(git -C "$ROOT/ref/$m" diff --stat "$want..$got" 2>/dev/null | tail -1)"
    fi
    drift+="ref/$m: $range$detail"$'\n'
  fi
done

status=0
if [ -n "$unchecked" ]; then
  echo "CANNOT CHECK (nothing was verified for these):"
  printf '%s' "$unchecked"
  status=2
fi

if [ -n "$drift" ]; then
  echo "UPSTREAM DRIFT DETECTED:"
  printf '%s' "$drift"
  echo "Triage with the pull-reflect skill (Port/Skip/Adapt), record in docs/drift-log.md,"
  echo "then run: $0 --update-lock"
  [ "$BOOTSTRAP" = "1" ] || echo "Tip: --bootstrap clones the mirrors so you can read the changed source."
elif [ -z "$unchecked" ]; then
  echo "no drift"
fi

if [ "$NOTIFY" = "1" ] && [ -n "$drift$unchecked" ] && command -v hermes >/dev/null 2>&1; then
  hermes send -q -t "$TARGET" -s "codex-plugin-hermes: upstream check" \
    "${drift}${unchecked}Run pull-reflect in the repo to triage." || true
fi

exit "$status"
