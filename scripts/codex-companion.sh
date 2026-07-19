#!/usr/bin/env bash
# Hermes Codex companion. Codex JSONL starts with {"type":"thread.started","thread_id":...}.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/codex-companion.sh"
MAX_JOBS=50
WORKER_MODE=false
ACTIVE_CHILD_PID=''

usage() {
  cat <<'EOF'
Usage: codex-companion.sh <subcommand> [flags]

Subcommands:
  setup [--json] [--enable-review-gate|--disable-review-gate]
  review [--wait|--background] [--base REF] [--scope auto|working-tree|branch]
  adversarial-review [review flags] [focus text]
  task [--background] [--write] [--resume-last|--fresh] [--model M] [--effort E] [prompt]
  transfer --source PATH [--json]
  status [job-id] [--all] [--json]
  result [job-id] [--json]
  task-resume-candidate [--json]
  cancel [job-id]
  task-worker <job-id>                 Internal background worker
  session-end                         Internal cleanup hook
  help

Review effort values: none, minimal, low, medium, high, xhigh.
Model alias: spark = gpt-5.3-codex-spark.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required. Install jq, then run /codex-setup."
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

epoch_now() {
  date '+%s'
}

sha16() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  fi
}

workspace_path() {
  local root
  if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    (cd "$root" && pwd -P)
  else
    pwd -P
  fi
}

WORKSPACE="$(workspace_path)"
WORKSPACE_NAME="$(basename "$WORKSPACE")"
WORKSPACE_SLUG="$(printf '%s' "$WORKSPACE_NAME" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
WORKSPACE_SLUG="${WORKSPACE_SLUG:-workspace}"
STATE_ROOT="${CODEX_COMPANION_STATE_ROOT:-${HERMES_HOME:-$HOME/.hermes}/codex-companion}"
WORKSPACE_DIR="$STATE_ROOT/${WORKSPACE_SLUG}-$(sha16 "$WORKSPACE")"
JOBS_DIR="$WORKSPACE_DIR/jobs"
STATE_FILE="$WORKSPACE_DIR/state.json"

init_state() {
  need_jq
  mkdir -p "$JOBS_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n '{version:1,config:{stop_review_gate:false},jobs:[]}' >"$STATE_FILE"
  fi
}

atomic_jq() {
  local target="$1"
  shift
  local tmp
  tmp="$(mktemp "$WORKSPACE_DIR/.json.XXXXXX")"
  if jq "$@" "$target" >"$tmp"; then
    mv "$tmp" "$target"
  else
    rm -f "$tmp"
    return 1
  fi
}

refresh_state() {
  local jobs_json tmp
  local -a files=("$JOBS_DIR"/*.json)
  if [[ -e "${files[0]}" ]]; then
    jobs_json="$(jq -s --argjson cap "$MAX_JOBS" 'map({id,kind,status,phase,title,summary,thread_id,created_at,updated_at,created_epoch,updated_epoch}) | sort_by(.updated_epoch) | reverse | .[:$cap]' "${files[@]}")"
  else
    jobs_json='[]'
  fi
  tmp="$(mktemp "$WORKSPACE_DIR/.state.XXXXXX")"
  jq --argjson jobs "$jobs_json" '.jobs=$jobs' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

base36() {
  local number="$1" digits='0123456789abcdefghijklmnopqrstuvwxyz' result='' remainder
  if ((number == 0)); then
    printf '0'
    return
  fi
  while ((number > 0)); do
    remainder=$((number % 36))
    result="${digits:remainder:1}${result}"
    number=$((number / 36))
  done
  printf '%s' "$result"
}

random6() {
  local value
  value="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6 || true)"
  printf '%-6s' "$value" | tr ' ' '0'
}

new_job_id() {
  printf '%s-%s-%s' "$1" "$(base36 "$(epoch_now)")" "$(random6)"
}

job_file() {
  printf '%s/%s.json' "$JOBS_DIR" "$1"
}

job_log() {
  printf '%s/%s.log' "$JOBS_DIR" "$1"
}

job_last() {
  printf '%s/%s.last' "$JOBS_DIR" "$1"
}

create_job() {
  local id="$1" kind="$2" title="$3" request="$4" now epoch file tmp
  now="$(iso_now)"
  epoch="$(epoch_now)"
  file="$(job_file "$id")"
  tmp="$(mktemp "$WORKSPACE_DIR/.job-create.XXXXXX")"
  jq -n \
    --arg id "$id" --arg kind "$kind" --arg title "$title" \
    --arg now "$now" --argjson epoch "$epoch" --argjson request "$request" \
    '{version:1,id:$id,kind:$kind,title:$title,summary:"Queued",status:"queued",phase:"queued",pid:null,pgid:null,thread_id:null,request:$request,result:null,created_at:$now,updated_at:$now,created_epoch:$epoch,updated_epoch:$epoch,started_epoch:null,finished_epoch:null}' \
    >"$tmp"
  mv "$tmp" "$file"
  : >"$(job_log "$id")"
  refresh_state
}

update_job() {
  local id="$1" filter="$2" file tmp now epoch
  file="$(job_file "$id")"
  [[ -f "$file" ]] || return 1
  now="$(iso_now)"
  epoch="$(epoch_now)"
  tmp="$(mktemp "$WORKSPACE_DIR/.job.XXXXXX")"
  if jq --arg now "$now" --argjson epoch "$epoch" "$filter | .updated_at=\$now | .updated_epoch=\$epoch" "$file" >"$tmp"; then
    mv "$tmp" "$file"
    refresh_state
  else
    rm -f "$tmp"
    return 1
  fi
}

log_job() {
  local id="$1"
  shift
  printf '[%s] %s\n' "$(iso_now)" "$*" >>"$(job_log "$id")"
}

resolve_job() {
  local reference="$1" mode="${2:-any}" file status
  local -a matches=()
  while IFS= read -r -d '' file; do
    status="$(jq -r '.status' "$file")"
    if [[ "$mode" == active && "$status" != queued && "$status" != running ]]; then
      continue
    fi
    matches+=("$file")
  done < <(find "$JOBS_DIR" -maxdepth 1 -type f -name "${reference}*.json" -print0 2>/dev/null)
  if ((${#matches[@]} == 0)); then
    return 1
  fi
  if ((${#matches[@]} > 1)); then
    return 2
  fi
  basename "${matches[0]}" .json
}

latest_job() {
  local jq_filter="$1"
  local -a files=("$JOBS_DIR"/*.json)
  if [[ ! -e "${files[0]}" ]]; then
    return 0
  fi
  jq -s -r "map($jq_filter) | sort_by(.updated_epoch) | reverse | .[0].id // empty" "${files[@]}"
}

normalize_args() {
  ARGS=("$@")
  if (($# == 1)) && [[ "$1" == *' '* ]]; then
    read -r -a ARGS <<<"$1"
  fi
}

validate_effort() {
  case "$1" in
    none|minimal|low|medium|high|xhigh) ;;
    *) die "Invalid effort '$1'. Use none, minimal, low, medium, high, or xhigh." ;;
  esac
}

codex_ready() {
  command -v codex >/dev/null 2>&1 || die "Codex CLI is not installed. Run npm install -g @openai/codex, then /codex-setup."
  codex login status >/dev/null 2>&1 || die "Codex is not authenticated. Run codex login, then /codex-setup."
}

extract_thread_id() {
  local log="$1"
  jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id // empty' "$log" 2>/dev/null | head -n 1
}

execute_codex() {
  local id="$1" sandbox="$2" prompt="$3" model="$4" effort="$5" resume_id="$6" schema="$7"
  local log last thread rc
  local -a command=(codex exec --json -C "$WORKSPACE" --sandbox "$sandbox" -o "$(job_last "$id")")
  # Repo checking is enabled by default. The installed CLI exposes only the
  # opt-out boolean --skip-git-repo-check, not a =false spelling.
  [[ -n "$model" ]] && command+=(--model "$model")
  [[ -n "$effort" ]] && command+=(-c "model_reasoning_effort=\"$effort\"")
  [[ -n "$schema" ]] && command+=(--output-schema "$schema")
  if [[ -n "$resume_id" ]]; then
    command+=(resume "$resume_id" "$prompt")
  else
    command+=("$prompt")
  fi
  log="$(job_log "$id")"
  last="$(job_last "$id")"
  log_job "$id" "Starting Codex execution."
  set +e
  if [[ "$WORKER_MODE" == true ]]; then
    "${command[@]}" >>"$log" 2>&1 &
    ACTIVE_CHILD_PID=$!
    wait "$ACTIVE_CHILD_PID"
    rc=$?
    ACTIVE_CHILD_PID=''
  else
    "${command[@]}" >>"$log" 2>&1
    rc=$?
  fi
  set -e
  thread="$(extract_thread_id "$log")"
  if [[ -n "$thread" ]]; then
    update_job "$id" ".thread_id=\"$thread\"" >/dev/null
  fi
  if [[ ! -s "$last" ]]; then
    tail -n 40 "$log" >"$last"
  fi
  return "$rc"
}

execute_native_review() {
  local id="$1" scope="$2" base="$3" log last thread rc
  local -a command=(codex exec --json -C "$WORKSPACE" --sandbox read-only -o "$(job_last "$id")" review)
  if [[ "$scope" == working-tree ]]; then
    command+=(--uncommitted)
  else
    command+=(--base "$base")
  fi
  log="$(job_log "$id")"
  last="$(job_last "$id")"
  log_job "$id" "Starting native Codex review."
  set +e
  if [[ "$WORKER_MODE" == true ]]; then
    "${command[@]}" >>"$log" 2>&1 &
    ACTIVE_CHILD_PID=$!
    wait "$ACTIVE_CHILD_PID"
    rc=$?
    ACTIVE_CHILD_PID=''
  else
    "${command[@]}" >>"$log" 2>&1
    rc=$?
  fi
  set -e
  thread="$(extract_thread_id "$log")"
  if [[ -n "$thread" ]]; then
    update_job "$id" ".thread_id=\"$thread\"" >/dev/null
  fi
  [[ -s "$last" ]] || tail -n 40 "$log" >"$last"
  return "$rc"
}

finish_job() {
  local id="$1" rc="$2" current output summary escaped
  current="$(jq -r '.status' "$(job_file "$id")")"
  [[ "$current" == cancelled ]] && return 0
  output="$(cat "$(job_last "$id")" 2>/dev/null || true)"
  summary="$(printf '%s\n' "$output" | awk 'NF {print; exit}' | cut -c1-160)"
  summary="${summary:-Codex produced no final message.}"
  escaped="$(jq -Rn --arg value "$output" '$value')"
  if ((rc == 0)); then
    update_job "$id" ".status=\"completed\" | .phase=\"completed\" | .summary=$(jq -Rn --arg v "$summary" '$v') | .result=$escaped | .finished_epoch=(now|floor)" >/dev/null
    log_job "$id" "Final output"
    printf '%s\n' "$output" >>"$(job_log "$id")"
  else
    update_job "$id" ".status=\"failed\" | .phase=\"failed\" | .summary=$(jq -Rn --arg v "$summary" '$v') | .result=$escaped | .finished_epoch=(now|floor)" >/dev/null
    log_job "$id" "Codex exited with status $rc."
  fi
}

spawn_worker() {
  local id="$1" pid
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SELF" task-worker "$id" >/dev/null 2>&1 &
    pid=$!
    update_job "$id" ".pid=$pid | .pgid=$pid" >/dev/null
    return
  fi
  nohup "$SELF" task-worker "$id" >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  update_job "$id" ".pid=$pid | .pgid=null" >/dev/null
}

terminate_worker() {
  local child="$ACTIVE_CHILD_PID"
  trap - HUP INT TERM
  if [[ -n "$child" ]]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  exit 143
}

notify_job() {
  local id="$1" kind status summary message
  kind="$(jq -r '.kind' "$(job_file "$id")")"
  status="$(jq -r '.status' "$(job_file "$id")")"
  summary="$(jq -r '.summary' "$(job_file "$id")")"
  message="$summary
Check /codex-status $id
Fetch /codex-result $id"
  hermes send -q -t "${CODEX_COMPANION_NOTIFY_TARGET:-telegram}" -s "Codex $kind $status" "$message" >/dev/null 2>&1 || true
}

default_base() {
  local base
  base="$(git -C "$WORKSPACE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  base="${base#origin/}"
  if [[ -n "$base" ]]; then
    printf '%s' "$base"
  elif git -C "$WORKSPACE" show-ref --verify --quiet refs/heads/main; then
    printf 'main'
  elif git -C "$WORKSPACE" show-ref --verify --quiet refs/heads/master; then
    printf 'master'
  else
    printf 'main'
  fi
}

working_tree_metrics() {
  local files lines file count
  files="$(git -C "$WORKSPACE" status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
  lines="$(git -C "$WORKSPACE" diff --numstat HEAD 2>/dev/null | awk '{a+=$1+$2} END {print a+0}')"
  while IFS= read -r file; do
    [[ -n "$file" && -f "$WORKSPACE/$file" ]] || continue
    count="$(wc -l <"$WORKSPACE/$file" | tr -d ' ')"
    lines=$((lines + count))
  done < <(git -C "$WORKSPACE" status --porcelain --untracked-files=all | sed -n 's/^?? //p')
  printf '%s %s' "$files" "$lines"
}

branch_metrics() {
  local base="$1" files lines
  files="$(git -C "$WORKSPACE" diff --name-only "$base"...HEAD 2>/dev/null | wc -l | tr -d ' ')"
  lines="$(git -C "$WORKSPACE" diff --numstat "$base"...HEAD 2>/dev/null | awk '{a+=$1+$2} END {print a+0}')"
  printf '%s %s' "$files" "$lines"
}

select_review_scope() {
  local requested="$1"
  if [[ "$requested" != auto ]]; then
    printf '%s' "$requested"
  elif [[ -n "$(git -C "$WORKSPACE" status --porcelain --untracked-files=all)" ]]; then
    printf 'working-tree'
  else
    printf 'branch'
  fi
}

render_adversarial() {
  local output="$1"
  if jq -e 'type=="object" and (.verdict|type=="string") and (.findings|type=="array")' >/dev/null 2>&1 <<<"$output"; then
    jq -r '
      def rank: if .=="critical" then 0 elif .=="high" then 1 elif .=="medium" then 2 else 3 end;
      "# Codex Adversarial Review\n\nVerdict: **\(.verdict)**\n\n\(.summary)\n",
      ((.findings | sort_by(.severity | rank))[] |
        "## [\(.severity)] \(.title) (\(.file):\(.line_start))\n\n\(.body)\n\nRecommendation: \(.recommendation)\n"),
      "## Next steps\n",
      (if (.next_steps|length)==0 then "- None." else (.next_steps[] | "- \(.)") end)
    ' <<<"$output"
  else
    printf '# Codex Adversarial Review\n\n%s\n\nParse error: Codex did not return valid structured review JSON.\n' "$output"
  fi
}

store_rendered_adversarial() {
  local id="$1" raw tmp
  raw="$(cat "$(job_last "$id")")"
  tmp="$(mktemp "$WORKSPACE_DIR/.review.XXXXXX")"
  render_adversarial "$raw" >"$tmp"
  mv "$tmp" "$(job_last "$id")"
}

review_context() {
  local scope="$1" base="$2" metrics files bytes diff file
  if [[ "$scope" == working-tree ]]; then
    metrics="$(working_tree_metrics)"
    diff="$(git -C "$WORKSPACE" diff HEAD 2>/dev/null || true)"
    while IFS= read -r file; do
      [[ -f "$WORKSPACE/$file" ]] || continue
      if [[ "$(wc -c <"$WORKSPACE/$file")" -le 24576 ]] && LC_ALL=C grep -Iq . "$WORKSPACE/$file"; then
        diff+=$'\n\n--- Untracked file: '
        diff+="$file"
        diff+=$' ---\n'
        diff+="$(sed -n '1,1200p' "$WORKSPACE/$file")"
      fi
    done < <(git -C "$WORKSPACE" status --porcelain --untracked-files=all | sed -n 's/^?? //p')
  else
    metrics="$(branch_metrics "$base")"
    diff="$(git -C "$WORKSPACE" diff "$base"...HEAD 2>/dev/null || true)"
  fi
  read -r files _ <<<"$metrics"
  bytes="$(printf '%s' "$diff" | wc -c | tr -d ' ')"
  if ((files <= 2 && bytes <= 262144)); then
    REVIEW_GUIDANCE="Review the inline repository diff below."
    REVIEW_INPUT="$diff"
  else
    REVIEW_GUIDANCE="Collect the review context yourself with read-only git commands in the current repository. Do not modify files."
    REVIEW_INPUT="The change is too large to inline safely; inspect the selected $scope scope directly."
  fi
}

command_setup() {
  normalize_args "$@"
  local json=false gate_action='' cleanup_action='' codex_available=false authenticated=false jq_available=false hermes_available=false version=''
  local arg
  for arg in "${ARGS[@]}"; do
    case "$arg" in
      --json) json=true ;;
      --enable-review-gate) gate_action=true ;;
      --disable-review-gate) gate_action=false ;;
      --cleanup-on-session-end) cleanup_action=true ;;
      --no-cleanup-on-session-end) cleanup_action=false ;;
      '') ;;
      *) die "Unknown setup flag: $arg" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 && jq_available=true
  if [[ "$jq_available" != true ]]; then
    printf 'jq is required to initialize Codex companion state.\n' >&2
    exit 1
  fi
  init_state
  if command -v codex >/dev/null 2>&1; then
    codex_available=true
    version="$(codex --version 2>/dev/null || true)"
    codex login status >/dev/null 2>&1 && authenticated=true
  fi
  command -v hermes >/dev/null 2>&1 && hermes_available=true
  if [[ -n "$gate_action" ]]; then
    atomic_jq "$STATE_FILE" --argjson enabled "$gate_action" '.config.stop_review_gate=$enabled'
  fi
  if [[ -n "$cleanup_action" ]]; then
    atomic_jq "$STATE_FILE" --argjson enabled "$cleanup_action" '.config.cleanup_on_session_end=$enabled'
  fi
  local gate
  gate="$(jq -r '.config.stop_review_gate // false' "$STATE_FILE")"
  if [[ "$json" == true ]]; then
    jq -n --argjson ca "$codex_available" --arg cv "$version" --argjson au "$authenticated" \
      --argjson ja "$jq_available" --argjson ha "$hermes_available" --arg sd "$WORKSPACE_DIR" --argjson rg "$gate" \
      '{codex_available:$ca,codex_version:$cv,authenticated:$au,jq_available:$ja,hermes_send_available:$ha,state_dir:$sd,review_gate:$rg}'
  else
    printf '# Codex Setup\n\n'
    printf -- '- Codex CLI: %s%s\n' "$codex_available" "${version:+ ($version)}"
    printf -- '- Authenticated: %s\n- jq: %s\n- Hermes send: %s\n- State directory writable: %s\n- Review gate: %s\n' \
      "$authenticated" "$jq_available" "$hermes_available" "$([[ -w "$WORKSPACE_DIR" ]] && printf true || printf false)" "$gate"
    printf -- '- Full dependency report: %s/scripts/doctor.sh\n' "$PLUGIN_ROOT"
    if [[ "$codex_available" != true ]]; then
      printf '\nNext: npm install -g @openai/codex\n'
    elif [[ "$authenticated" != true ]]; then
      printf '\nNext: codex login\n'
    fi
  fi
}

parse_review_args() {
  local allow_focus="$1"
  shift
  normalize_args "$@"
  REVIEW_MODE="auto"
  REVIEW_SCOPE=auto
  REVIEW_BASE=''
  REVIEW_FOCUS=''
  local -a focus=()
  local index=0 arg
  while ((index < ${#ARGS[@]})); do
    arg="${ARGS[index]}"
    case "$arg" in
      --wait) REVIEW_MODE="wait" ;;
      --background) REVIEW_MODE="background" ;;
      --scope)
        ((index += 1))
        ((index < ${#ARGS[@]})) || die "--scope requires a value."
        REVIEW_SCOPE="${ARGS[index]}"
        case "$REVIEW_SCOPE" in auto|working-tree|branch) ;; *) die "Invalid review scope: $REVIEW_SCOPE" ;; esac
        ;;
      --base)
        ((index += 1))
        ((index < ${#ARGS[@]})) || die "--base requires a ref."
        REVIEW_BASE="${ARGS[index]}"
        ;;
      --json) ;;
      '') ;;
      --*) die "Unknown review flag: $arg" ;;
      *) focus+=("$arg") ;;
    esac
    ((index += 1))
  done
  if [[ "$allow_focus" != true && ${#focus[@]} -gt 0 ]]; then
    die "Native review does not accept focus text. Use /codex-adversarial-review."
  fi
  REVIEW_FOCUS="${focus[*]:-}"
  REVIEW_BASE="${REVIEW_BASE:-$(default_base)}"
  REVIEW_SCOPE="$(select_review_scope "$REVIEW_SCOPE")"
  if [[ "$REVIEW_MODE" == auto ]]; then
    local metrics files lines
    if [[ "$REVIEW_SCOPE" == working-tree ]]; then
      metrics="$(working_tree_metrics)"
    else
      metrics="$(branch_metrics "$REVIEW_BASE")"
    fi
    read -r files lines <<<"$metrics"
    if ((files <= 2 && lines <= 200)); then REVIEW_MODE="wait"; else REVIEW_MODE="background"; fi
  fi
}

command_review() {
  parse_review_args false "$@"
  codex_ready
  local id request rc
  id="$(new_job_id review)"
  request="$(jq -n --arg op review --arg scope "$REVIEW_SCOPE" --arg base "$REVIEW_BASE" '{operation:$op,scope:$scope,base:$base}')"
  create_job "$id" review "Codex review" "$request"
  if [[ "$REVIEW_MODE" == background ]]; then
    spawn_worker "$id"
    printf 'Codex review started in the background as %s. Check /codex-status for progress.\n' "$id"
    return
  fi
  update_job "$id" '.status="running" | .phase="reviewing" | .started_epoch=(now|floor)' >/dev/null
  set +e; execute_native_review "$id" "$REVIEW_SCOPE" "$REVIEW_BASE"; rc=$?; set -e
  finish_job "$id" "$rc"
  cat "$(job_last "$id")"
  return "$rc"
}

command_adversarial() {
  parse_review_args true "$@"
  codex_ready
  local id request rc template prompt target
  target="$([[ "$REVIEW_SCOPE" == working-tree ]] && printf 'working tree' || printf 'branch against %s' "$REVIEW_BASE")"
  review_context "$REVIEW_SCOPE" "$REVIEW_BASE"
  template="$(cat "$PLUGIN_ROOT/prompts/adversarial-review.md")"
  prompt="${template//\{\{TARGET_LABEL\}\}/$target}"
  prompt="${prompt//\{\{USER_FOCUS\}\}/${REVIEW_FOCUS:-No additional focus supplied.}}"
  prompt="${prompt//\{\{REVIEW_COLLECTION_GUIDANCE\}\}/$REVIEW_GUIDANCE}"
  prompt="${prompt//\{\{REVIEW_INPUT\}\}/$REVIEW_INPUT}"
  id="$(new_job_id review)"
  request="$(jq -n --arg op adversarial-review --arg prompt "$prompt" '{operation:$op,prompt:$prompt,sandbox:"read-only",schema:true}')"
  create_job "$id" review "Codex adversarial review" "$request"
  if [[ "$REVIEW_MODE" == background ]]; then
    spawn_worker "$id"
    printf 'Codex adversarial review started in the background as %s. Check /codex-status for progress.\n' "$id"
    return
  fi
  update_job "$id" '.status="running" | .phase="reviewing" | .started_epoch=(now|floor)' >/dev/null
  set +e; execute_codex "$id" read-only "$prompt" '' '' '' "$PLUGIN_ROOT/schemas/review-output.schema.json"; rc=$?; set -e
  store_rendered_adversarial "$id"
  finish_job "$id" "$rc"
  cat "$(job_last "$id")"
  return "$rc"
}

parse_task_args() {
  normalize_args "$@"
  TASK_BACKGROUND=false TASK_WRITE=false TASK_RESUME=false TASK_JSON=false TASK_MODEL='' TASK_EFFORT='' TASK_PROMPT=''
  local -a prompt=()
  local index=0 arg
  while ((index < ${#ARGS[@]})); do
    arg="${ARGS[index]}"
    case "$arg" in
      --background) TASK_BACKGROUND=true ;;
      --wait) TASK_BACKGROUND=false ;;
      --write) TASK_WRITE=true ;;
      --resume-last|--resume) TASK_RESUME=true ;;
      --fresh) TASK_RESUME=false ;;
      --json) TASK_JSON=true ;;
      --model)
        ((index += 1)); ((index < ${#ARGS[@]})) || die "--model requires a value."
        TASK_MODEL="${ARGS[index]}"; [[ "$TASK_MODEL" == spark ]] && TASK_MODEL='gpt-5.3-codex-spark'
        ;;
      --effort)
        ((index += 1)); ((index < ${#ARGS[@]})) || die "--effort requires a value."
        TASK_EFFORT="${ARGS[index]}"; validate_effort "$TASK_EFFORT"
        ;;
      '') ;;
      --*) die "Unknown task flag: $arg" ;;
      *) prompt+=("$arg") ;;
    esac
    ((index += 1))
  done
  TASK_PROMPT="${prompt[*]:-}"
}

task_resume_id() {
  local running candidate
  running="$(latest_job 'select(.kind=="task" and (.status=="queued" or .status=="running"))')"
  [[ -z "$running" ]] || die "Task $running is still running; wait or cancel it before resuming."
  candidate="$(latest_job 'select(.kind=="task" and .status=="completed" and (.thread_id // "") != "")')"
  [[ -n "$candidate" ]] || die "No completed Codex task with a session ID is available to resume."
  jq -r '.thread_id' "$(job_file "$candidate")"
}

command_task() {
  parse_task_args "$@"
  codex_ready
  local resume_id='' sandbox=read-only id request rc title
  [[ "$TASK_WRITE" == true ]] && sandbox=workspace-write
  if [[ "$TASK_RESUME" == true ]]; then
    resume_id="$(task_resume_id)"
    TASK_PROMPT="${TASK_PROMPT:-Continue from the current thread state. Pick the next highest-value step and execute it.}"
  fi
  [[ -n "$TASK_PROMPT" ]] || die "Provide a task prompt."
  title="$(printf '%s' "$TASK_PROMPT" | tr '\n' ' ' | cut -c1-80)"
  id="$(new_job_id task)"
  request="$(jq -n --arg op task --arg prompt "$TASK_PROMPT" --arg sandbox "$sandbox" --arg model "$TASK_MODEL" --arg effort "$TASK_EFFORT" --arg resume "$resume_id" '{operation:$op,prompt:$prompt,sandbox:$sandbox,model:$model,effort:$effort,resume_id:$resume}')"
  create_job "$id" task "$title" "$request"
  if [[ "$TASK_BACKGROUND" == true ]]; then
    spawn_worker "$id"
    if [[ "$TASK_JSON" == true ]]; then
      jq -n --arg id "$id" --arg title "$title" '{job_id:$id,status:"queued",title:$title}'
    else
      printf '"%s" started in the background as %s.\n' "$title" "$id"
    fi
    return
  fi
  update_job "$id" '.status="running" | .phase="executing" | .started_epoch=(now|floor)' >/dev/null
  set +e; execute_codex "$id" "$sandbox" "$TASK_PROMPT" "$TASK_MODEL" "$TASK_EFFORT" "$resume_id" ''; rc=$?; set -e
  finish_job "$id" "$rc"
  local output thread
  output="$(cat "$(job_last "$id")")"
  thread="$(jq -r '.thread_id // empty' "$(job_file "$id")")"
  if [[ "$TASK_JSON" == true ]]; then
    jq -n --arg id "$id" --arg status "$([[ $rc -eq 0 ]] && printf completed || printf failed)" --arg raw "$output" --arg thread "$thread" '{job_id:$id,status:$status,raw_output:$raw,thread_id:(if ($thread|length)>0 then $thread else null end)}'
  else
    printf '%s\n' "$output"
    if [[ -n "$thread" ]]; then
      printf 'Codex session ID: %s\nResume in Codex: codex resume %s\n' "$thread" "$thread"
    fi
  fi
  return "$rc"
}

command_task_worker() {
  local id="${1:-}" file operation rc=1
  [[ -n "$id" ]] || die "task-worker requires a job ID."
  file="$(job_file "$id")"
  [[ -f "$file" ]] || die "Unknown job: $id"
  WORKER_MODE=true
  trap terminate_worker HUP INT TERM
  operation="$(jq -r '.request.operation' "$file")"
  update_job "$id" ".status=\"running\" | .phase=\"executing\" | .started_epoch=(now|floor) | .pid=$BASHPID" >/dev/null
  case "$operation" in
    review)
      local scope base
      scope="$(jq -r '.request.scope' "$file")"; base="$(jq -r '.request.base' "$file")"
      set +e; execute_native_review "$id" "$scope" "$base"; rc=$?; set -e
      ;;
    adversarial-review|task)
      local prompt sandbox model effort resume schema=''
      prompt="$(jq -r '.request.prompt' "$file")"; sandbox="$(jq -r '.request.sandbox' "$file")"
      model="$(jq -r '.request.model // empty' "$file")"; effort="$(jq -r '.request.effort // empty' "$file")"
      resume="$(jq -r '.request.resume_id // empty' "$file")"
      [[ "$operation" == adversarial-review ]] && schema="$PLUGIN_ROOT/schemas/review-output.schema.json"
      set +e; execute_codex "$id" "$sandbox" "$prompt" "$model" "$effort" "$resume" "$schema"; rc=$?; set -e
      if [[ "$operation" == adversarial-review ]]; then
        store_rendered_adversarial "$id"
      fi
      ;;
    *) log_job "$id" "Unknown worker operation: $operation" ;;
  esac
  finish_job "$id" "$rc"
  notify_job "$id"
  return "$rc"
}

command_transfer() {
  normalize_args "$@"
  local source='' json=false index=0 arg transcript prompt id request rc output thread
  while ((index < ${#ARGS[@]})); do
    arg="${ARGS[index]}"
    case "$arg" in
      --source) ((index += 1)); ((index < ${#ARGS[@]})) || die "--source requires a path."; source="${ARGS[index]}" ;;
      --json) json=true ;;
      '') ;;
      *) die "Unknown transfer argument: $arg" ;;
    esac
    ((index += 1))
  done
  if [[ -z "$source" ]]; then
    printf 'Export the Hermes session first (for example with `hermes dump`), then run /codex-transfer --source <export.jsonl|markdown>.\n' >&2
    return 1
  fi
  [[ -f "$source" ]] || die "Transfer source does not exist: $source"
  codex_ready
  transcript="$(tail -c 102400 "$source")"
  prompt="You are taking over this conversation from Hermes. Transcript follows. Preserve its goals, decisions, constraints, and unfinished work.

$transcript"
  id="$(new_job_id task)"
  request="$(jq -n --arg op transfer --arg source "$source" '{operation:$op,source:$source}')"
  create_job "$id" task "Hermes session transfer" "$request"
  update_job "$id" '.status="running" | .phase="transferring" | .started_epoch=(now|floor)' >/dev/null
  set +e; execute_codex "$id" read-only "$prompt" '' '' '' ''; rc=$?; set -e
  finish_job "$id" "$rc"
  output="$(cat "$(job_last "$id")")"; thread="$(jq -r '.thread_id // empty' "$(job_file "$id")")"
  if [[ "$json" == true ]]; then
    jq -n --arg id "$id" --arg raw "$output" --arg thread "$thread" '{job_id:$id,raw_output:$raw,thread_id:(if ($thread|length)>0 then $thread else null end)}'
  else
    printf 'Transferred the Hermes session into a Codex thread.\nCodex session ID: %s\nResume in Codex: codex resume %s\n' "$thread" "$thread"
  fi
  return "$rc"
}

elapsed_text() {
  local start="$1" end="$2" seconds
  seconds=$((end - start)); ((seconds < 0)) && seconds=0
  if ((seconds < 60)); then printf '%ss' "$seconds"; elif ((seconds < 3600)); then printf '%sm' "$((seconds / 60))"; else printf '%sh%sm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"; fi
}

command_status() {
  normalize_args "$@"
  local reference='' all=false json=false arg id file now status start end elapsed
  for arg in "${ARGS[@]}"; do
    case "$arg" in --all) all=true ;; --json) json=true ;; '') ;; --*) die "Unknown status flag: $arg" ;; *) [[ -z "$reference" ]] || die "Only one job ID may be supplied."; reference="$arg" ;; esac
  done
  refresh_state
  if [[ -n "$reference" ]]; then
    if ! id="$(resolve_job "$reference")"; then die "No unique job matches '$reference'."; fi
    file="$(job_file "$id")"
    if [[ "$json" == true ]]; then
      jq --arg log "$(tail -n 20 "$(job_log "$id")")" '. + {log_tail:$log}' "$file"
    else
      status="$(jq -r '.status' "$file")"; start="$(jq -r '.started_epoch // .created_epoch' "$file")"; now="$(epoch_now)"; end="$(jq -r '.finished_epoch // empty' "$file")"; end="${end:-$now}"; elapsed="$(elapsed_text "$start" "$end")"
      printf '# Codex Job %s\n\n- Kind: %s\n- Status: %s\n- Phase: %s\n- Elapsed: %s\n- Summary: %s\n- Session ID: %s\n\n## Log tail\n\n```text\n' "$id" "$(jq -r '.kind' "$file")" "$status" "$(jq -r '.phase' "$file")" "$elapsed" "$(jq -r '.summary' "$file")" "$(jq -r '.thread_id // "-"' "$file")"
      tail -n 20 "$(job_log "$id")"
      printf '```\n'
    fi
    return
  fi
  local jobs
  if [[ "$all" == true ]]; then
    jobs="$(jq '.jobs' "$STATE_FILE")"
  else
    jobs="$(jq '[.jobs[] | select(.status=="queued" or .status=="running")] + ([.jobs[] | select(.status!="queued" and .status!="running")][0:5]) | unique_by(.id) | sort_by(.updated_epoch) | reverse' "$STATE_FILE")"
  fi
  if [[ "$json" == true ]]; then
    jq -n --arg workspace "$WORKSPACE" --argjson jobs "$jobs" '{workspace:$workspace,jobs:$jobs}'
  else
    printf '| ID | kind | status | phase | elapsed | summary |\n|---|---|---|---|---:|---|\n'
    now="$(epoch_now)"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      start="$(jq -r '.created_epoch' <<<"$file")"; end="$(jq -r '.finished_epoch // empty' <<<"$file")"; end="${end:-$now}"
      printf '| %s | %s | %s | %s | %s | %s |\n' "$(jq -r '.id' <<<"$file")" "$(jq -r '.kind' <<<"$file")" "$(jq -r '.status' <<<"$file")" "$(jq -r '.phase' <<<"$file")" "$(elapsed_text "$start" "$end")" "$(jq -r '.summary | gsub("\\|"; "\\\\|")' <<<"$file")"
    done < <(jq -c '.[]' <<<"$jobs")
    printf '\nUse /codex-status <job-id>, /codex-result <job-id>, or /codex-cancel <job-id>.\n'
  fi
}

command_result() {
  normalize_args "$@"
  local reference='' json=false arg id file status output thread
  for arg in "${ARGS[@]}"; do case "$arg" in --json) json=true ;; '') ;; --*) die "Unknown result flag: $arg" ;; *) reference="$arg" ;; esac; done
  if [[ -z "$reference" ]]; then
    reference="$(latest_job 'select(.status=="completed")')"
    if [[ -z "$reference" ]]; then printf 'No completed Codex jobs are available. Check /codex-status.\n'; return 0; fi
  fi
  if ! id="$(resolve_job "$reference")"; then die "No unique job matches '$reference'."; fi
  file="$(job_file "$id")"; status="$(jq -r '.status' "$file")"
  if [[ "$status" != completed && "$status" != failed && "$status" != cancelled ]]; then
    printf 'Job %s is %s. Check /codex-status %s for progress.\n' "$id" "$status" "$id"
    return 0
  fi
  output="$(cat "$(job_last "$id")" 2>/dev/null || jq -r '.result // empty' "$file")"; thread="$(jq -r '.thread_id // empty' "$file")"
  if [[ "$json" == true ]]; then
    jq -n --arg id "$id" --arg status "$status" --arg raw "$output" --arg thread "$thread" '{job_id:$id,status:$status,raw_output:$raw,thread_id:(if ($thread|length)>0 then $thread else null end)}'
  else
    printf '%s\n' "$output"
    if [[ -n "$thread" ]]; then printf 'Codex session ID: %s\nResume in Codex: codex resume %s\n' "$thread" "$thread"; fi
  fi
}

command_resume_candidate() {
  normalize_args "$@"
  local json=false arg id candidate
  for arg in "${ARGS[@]}"; do case "$arg" in --json) json=true ;; '') ;; *) die "Unknown task-resume-candidate flag: $arg" ;; esac; done
  id="$(latest_job 'select(.kind=="task" and .status=="completed" and (.thread_id // "") != "")')"
  if [[ -n "$id" ]]; then candidate="$(jq '{id,status,title,summary,thread_id,updated_at}' "$(job_file "$id")")"; else candidate=null; fi
  if [[ "$json" == true ]]; then
    jq -n --argjson candidate "$candidate" '{available:($candidate != null),candidate:$candidate}'
  elif [[ -n "$id" ]]; then
    printf 'Resume candidate: %s (%s)\n' "$id" "$(jq -r '.title' "$(job_file "$id")")"
  else
    printf 'No resumable Codex task is available.\n'
  fi
}

command_cancel() {
  normalize_args "$@"
  local reference="${ARGS[0]:-}" id file pid pgid active_count
  if [[ -z "$reference" ]]; then
    active_count="$(jq '[.jobs[] | select(.status=="queued" or .status=="running")] | length' "$STATE_FILE")"
    if ((active_count == 0)); then printf 'No active Codex jobs to cancel.\n'; return 0; fi
    if ((active_count > 1)); then die "Several jobs are active; provide a job ID from /codex-status."; fi
    reference="$(jq -r '.jobs[] | select(.status=="queued" or .status=="running") | .id' "$STATE_FILE")"
  fi
  if ! id="$(resolve_job "$reference" active)"; then die "No unique active job matches '$reference'."; fi
  file="$(job_file "$id")"; pid="$(jq -r '.pid // empty' "$file")"; pgid="$(jq -r '.pgid // empty' "$file")"
  if [[ -n "$pgid" ]] && kill -- "-$pgid" 2>/dev/null; then
    :
  elif [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
  update_job "$id" '.status="cancelled" | .phase="cancelled" | .summary="Cancelled by user." | .finished_epoch=(now|floor)' >/dev/null
  log_job "$id" "Cancelled by user."
  printf 'Cancelled Codex job %s.\n' "$id"
}

command_session_end() {
  local cleanup ids id
  refresh_state
  cleanup="$(jq -r '.config.cleanup_on_session_end // false' "$STATE_FILE")"
  if [[ "$cleanup" == true ]]; then
    ids="$(jq -r '.jobs[] | select(.status=="queued" or .status=="running") | .id' "$STATE_FILE")"
    while IFS= read -r id; do
      if [[ -n "$id" ]]; then
        command_cancel "$id" >/dev/null 2>&1 || true
      fi
    done <<<"$ids"
  fi
  local -a files=("$JOBS_DIR"/*.json) old=()
  if [[ -e "${files[0]}" && ${#files[@]} -gt $MAX_JOBS ]]; then
    mapfile -t old < <(jq -s -r --argjson cap "$MAX_JOBS" 'sort_by(.updated_epoch) | reverse | .[$cap:][] | .id' "${files[@]}")
  fi
  for id in "${old[@]}"; do rm -f "$(job_file "$id")" "$(job_log "$id")" "$(job_last "$id")"; done
  refresh_state
}

main() {
  local subcommand="${1:-help}"
  (($# > 0)) && shift || true
  if [[ "$subcommand" == help || "$subcommand" == --help || "$subcommand" == -h ]]; then usage; return 0; fi
  init_state
  case "$subcommand" in
    setup) command_setup "$@" ;;
    review) command_review "$@" ;;
    adversarial-review) command_adversarial "$@" ;;
    task) command_task "$@" ;;
    task-worker) command_task_worker "$@" ;;
    transfer) command_transfer "$@" ;;
    status) command_status "$@" ;;
    result) command_result "$@" ;;
    task-resume-candidate) command_resume_candidate "$@" ;;
    cancel) command_cancel "$@" ;;
    session-end) command_session_end ;;
    *) usage >&2; return 1 ;;
  esac
}

main "$@"
