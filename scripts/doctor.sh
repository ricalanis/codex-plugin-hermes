#!/usr/bin/env bash
set -u

MODE=human
if (($# > 1)); then
  printf 'Usage: %s [--json]\n' "${0##*/}" >&2
  exit 2
fi
if (($# == 1)); then
  if [[ "$1" != --json ]]; then
    printf 'Usage: %s [--json]\n' "${0##*/}" >&2
    exit 2
  fi
  MODE=json
fi

DEPENDENCIES=(
  'required|bash|4.0|macOS: brew install bash; Debian/Ubuntu: apt install bash'
  'required|codex|0.144|npm install -g @openai/codex'
  'required|jq|1.6|macOS: brew install jq; Debian/Ubuntu: apt install jq'
  'required|git||macOS: xcode-select --install; Debian/Ubuntu: apt install git'
  'required|posix-userland||macOS: included; Debian/Ubuntu: apt install coreutils findutils grep sed mawk'
  'optional|hermes||Install Hermes Agent if background-job notifications are wanted.'
  'optional|setsid||Linux: install util-linux; macOS uses the built-in nohup fallback.'
  'development|shellcheck||macOS: brew install shellcheck; Debian/Ubuntu: apt install shellcheck'
  'development|python3||macOS: brew install python; Debian/Ubuntu: apt install python3'
)

version_at_least() {
  local actual="$1" minimum="$2" actual_major=0 actual_minor=0 minimum_major=0 minimum_minor=0
  if [[ "$actual" =~ ([0-9]+)\.([0-9]+) ]]; then
    actual_major="${BASH_REMATCH[1]}"
    actual_minor="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  if [[ "$minimum" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    minimum_major="${BASH_REMATCH[1]}"
    minimum_minor="${BASH_REMATCH[2]}"
  fi
  ((actual_major > minimum_major || (actual_major == minimum_major && actual_minor >= minimum_minor)))
}

inspect_dependency() {
  local name="$1" minimum="$2"
  DEP_PRESENT=false
  DEP_VERSION=''
  case "$name" in
    posix-userland)
      DEP_PRESENT=true
      for utility in awk basename cat cut date dirname find grep head mkdir mktemp mv nohup rm sed tail tr wc; do
        if ! command -v "$utility" >/dev/null 2>&1; then
          DEP_PRESENT=false
        fi
      done
      if command -v sha256sum >/dev/null 2>&1; then
        DEP_VERSION='hash: sha256sum'
      elif command -v shasum >/dev/null 2>&1; then
        DEP_VERSION='hash: shasum'
      else
        DEP_PRESENT=false
      fi
      ;;
    bash)
      if command -v bash >/dev/null 2>&1; then
        DEP_VERSION="$(bash --version 2>/dev/null | head -n 1)"
        version_at_least "$DEP_VERSION" "$minimum" && DEP_PRESENT=true
      fi
      ;;
    codex)
      if command -v codex >/dev/null 2>&1; then
        DEP_VERSION="$(codex --version 2>/dev/null | head -n 1)"
        version_at_least "$DEP_VERSION" "$minimum" && DEP_PRESENT=true
      fi
      ;;
    jq)
      if command -v jq >/dev/null 2>&1; then
        DEP_VERSION="$(jq --version 2>/dev/null | head -n 1)"
        version_at_least "$DEP_VERSION" "$minimum" && DEP_PRESENT=true
      fi
      ;;
    git|python3)
      if command -v "$name" >/dev/null 2>&1; then
        DEP_PRESENT=true
        DEP_VERSION="$("$name" --version 2>/dev/null | head -n 1)"
      fi
      ;;
    hermes)
      if command -v hermes >/dev/null 2>&1; then
        DEP_PRESENT=true
        DEP_VERSION="$(hermes --version 2>/dev/null | head -n 1 || true)"
      fi
      ;;
    shellcheck)
      if command -v shellcheck >/dev/null 2>&1; then
        DEP_PRESENT=true
        DEP_VERSION="$(shellcheck --version 2>/dev/null | sed -n 's/^version: /ShellCheck /p' | head -n 1)"
      fi
      ;;
    setsid)
      if command -v setsid >/dev/null 2>&1; then
        DEP_PRESENT=true
        DEP_VERSION="$(setsid --version 2>/dev/null | head -n 1 || true)"
      fi
      ;;
    *)
      command -v "$name" >/dev/null 2>&1 && DEP_PRESENT=true
      ;;
  esac
}

json_string() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

required_missing=0
first=true
if [[ "$MODE" == json ]]; then
  printf '{"dependencies":['
else
  printf 'Codex companion dependency report\n'
fi

for entry in "${DEPENDENCIES[@]}"; do
  IFS='|' read -r category name minimum hint <<<"$entry"
  inspect_dependency "$name" "$minimum"
  if [[ "$category" == required && "$DEP_PRESENT" != true ]]; then
    required_missing=$((required_missing + 1))
  fi
  if [[ "$MODE" == json ]]; then
    if [[ "$first" == true ]]; then first=false; else printf ','; fi
    printf '{"name":%s,"category":%s,"present":%s' "$(json_string "$name")" "$(json_string "$category")" "$DEP_PRESENT"
    if [[ -n "$DEP_VERSION" ]]; then
      printf ',"version":%s' "$(json_string "$DEP_VERSION")"
    fi
    printf '}'
  else
    if [[ "$DEP_PRESENT" == true ]]; then
      printf '  [present] %-22s (%s)%s\n' "$name" "$category" "${DEP_VERSION:+ — $DEP_VERSION}"
    else
      printf '  [missing] %-22s (%s)\n' "$name" "$category"
      printf '            Install: %s\n' "$hint"
    fi
  fi
done

if [[ "$MODE" == json ]]; then
  printf '],"required_ok":%s}\n' "$([[ $required_missing -eq 0 ]] && printf true || printf false)"
else
  printf '\nRequired dependencies missing: %d\n' "$required_missing"
fi

((required_missing == 0))
