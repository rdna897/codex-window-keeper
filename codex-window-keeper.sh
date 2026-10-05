#!/usr/bin/env bash
#
# codex-window-keeper.sh - start a Codex five-hour window after it expires.
#
# A Codex five-hour window only starts counting when a request is made.  This
# script sends one very cheap ephemeral request at the reset boundary so the
# window does not sit idle, then exits.  It sends at most one request per
# five-hour window.  It talks to OpenAI directly.
#
# Timing sources, in order of preference:
#   1. live report   GET https://chatgpt.com/backend-api/wham/usage
#                    (ChatGPT login token from $CODEX_HOME/auth.json)
#   2. own state     /var/lib/codex-window-keeper/last_success_epoch + 5 hours
#
# Two decision modes, because the usage report has two shapes:
#   * window in use (primary_window.used_percent > 0): the report carries a real
#     reset timestamp.  Wait for it, then send exactly one request.
#   * window idle (used_percent == 0): OpenAI reports reset_at as "now + 5h" on
#     every call, so that timestamp never arrives.  In this state we keep our own
#     five-hour cadence from the last successful trigger.
#
# The usage endpoint is undocumented.  If it is unreachable or rejects the token,
# the own-state fallback is used; the ping itself makes the Codex CLI refresh
# its token.
#
# A live request is sent only when the trigger is due AND LIVE_TRIGGER_ENABLED=1
# in /etc/default/codex-window-keeper.  Use --dry-run to see the decision and
# the exact command without sending a request.
#
# Verified against codex-cli 0.160.0: exec --ephemeral --json --model --config
# --sandbox --cd --skip-git-repo-check.
#
set -Eeuo pipefail
umask 077

DEFAULTS_FILE="/etc/default/codex-window-keeper"
if [[ -r "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

STATE_DIR="${STATE_DIR:-/var/lib/codex-window-keeper}"
LOCK_FILE="$STATE_DIR/keeper.lock"
LAST_SUCCESS_FILE="$STATE_DIR/last_success_epoch"
HISTORY_FILE="$STATE_DIR/trigger-history.log"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="${AUTH_FILE:-$CODEX_HOME/auth.json}"
USAGE_URL="${USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"
# Pins the ping to ChatGPT directly, ignoring any openai_base_url in config.toml
# (for example one pointing at a local proxy).
CODEX_BASE_URL="${CODEX_BASE_URL:-https://chatgpt.com/backend-api/codex}"

WINDOW_SECONDS="${WINDOW_SECONDS:-18000}"
LIVE_TRIGGER_ENABLED="${LIVE_TRIGGER_ENABLED:-0}"
KEEPER_MODEL="${KEEPER_MODEL:-gpt-6-luna}"
KEEPER_REASONING_EFFORT="${KEEPER_REASONING_EFFORT:-low}"
KEEPER_PROMPT="${KEEPER_PROMPT:-Reply with exactly: Hi}"
KEEPER_WORKDIR="${KEEPER_WORKDIR:-/tmp}"
EXEC_TIMEOUT_SECONDS="${EXEC_TIMEOUT_SECONDS:-180}"
CODEX_BIN="${CODEX_BIN:-}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  --help|-h)
    cat <<'EOF'
Usage: codex-window-keeper.sh [--dry-run]

Starts a Codex five-hour window once it has expired.  Live requests require
LIVE_TRIGGER_ENABLED=1 in /etc/default/codex-window-keeper.  --dry-run never
invokes Codex and never consumes usage.
EOF
    exit 0
    ;;
  *)
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

log() {
  printf '[codex-window-keeper] %s %s\n' "$(date --iso-8601=seconds)" "$*"
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

format_epoch() {
  if is_uint "${1:-}" && (( $1 > 0 )); then
    date --date="@$1" '+%Y-%m-%d %H:%M:%S %Z'
  else
    printf 'unknown'
  fi
}

if ! is_uint "$WINDOW_SECONDS" || (( WINDOW_SECONDS <= 0 )); then
  log "ERROR: WINDOW_SECONDS must be a positive integer"
  exit 1
fi
if [[ "$LIVE_TRIGGER_ENABLED" != 0 && "$LIVE_TRIGGER_ENABLED" != 1 ]]; then
  log "ERROR: LIVE_TRIGGER_ENABLED must be 0 or 1"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# The lock keeps a manual run and a timer run from sending two requests at once.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another run is already holding the lock; nothing to do"
  exit 0
fi

last_success_epoch=0
if [[ -r "$LAST_SUCCESS_FILE" ]]; then
  read -r candidate_last_success < "$LAST_SUCCESS_FILE" || true
  if is_uint "${candidate_last_success:-}"; then
    last_success_epoch="$candidate_last_success"
  fi
fi

now_epoch="$(date +%s)"

# Resolve the installed CLI up front so --dry-run can print the exact command.
if [[ -z "$CODEX_BIN" ]]; then
  if [[ -x "$CODEX_HOME/packages/standalone/current/bin/codex" ]]; then
    CODEX_BIN="$CODEX_HOME/packages/standalone/current/bin/codex"
  else
    CODEX_BIN="$(command -v codex || true)"
  fi
fi

# Read the five-hour window from the usage endpoint.  Sets usage_status ("ok" or
# a reason), quota_reset_epoch and quota_used_percent.  The token is passed to
# curl on stdin so it never appears in argv.
fetch_quota() {
  usage_status="ok"
  quota_reset_epoch=0
  quota_used_percent=-1
  local token account body code window
  token="$(jq -er '.tokens.access_token' "$AUTH_FILE" 2>/dev/null)" || {
    usage_status="no access token in $AUTH_FILE"
    return 1
  }
  account="$(jq -er '.tokens.account_id' "$AUTH_FILE" 2>/dev/null)" || {
    usage_status="no account_id in $AUTH_FILE"
    return 1
  }
  body="$(printf 'header = "Authorization: Bearer %s"\nheader = "chatgpt-account-id: %s"\n' "$token" "$account" |
    curl -sS -m 20 -K - -w '\n%{http_code}' "$USAGE_URL" 2>&1)" || {
    usage_status="usage request failed"
    return 1
  }
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "$code" != 200 ]]; then
    usage_status="usage endpoint returned HTTP $code"
    return 1
  fi
  window="$(jq -er '.rate_limit.primary_window | [.reset_at, .used_percent] | @tsv' <<<"$body" 2>/dev/null)" || {
    usage_status="usage response has no primary_window"
    return 1
  }
  IFS=$'\t' read -r quota_reset_epoch quota_used_percent <<<"$window"
  # used_percent can be fractional; the idle test only needs the integer part.
  quota_used_percent="${quota_used_percent%%.*}"
  if ! is_uint "$quota_reset_epoch" || ! is_uint "$quota_used_percent" || (( quota_used_percent > 100 )); then
    usage_status="unusable window (reset=$quota_reset_epoch percent=$quota_used_percent)"
    return 1
  fi
  return 0
}

quota_source="none"
due=0
due_reason=""

if fetch_quota; then
  quota_source="wham-usage"
  quota_reset_text="$(format_epoch "$quota_reset_epoch")"

  if (( quota_used_percent == 0 )); then
    # Fully recovered: no upstream reset to wait for, so keep our own cadence.
    if (( last_success_epoch == 0 )); then
      due=1
      due_reason="five-hour budget is fully recovered and no keeper trigger has ever been recorded"
    elif (( now_epoch - last_success_epoch >= WINDOW_SECONDS )); then
      due=1
      due_reason="five-hour budget is fully recovered and $(format_epoch "$last_success_epoch") is more than $WINDOW_SECONDS seconds ago"
    else
      next_self_epoch="$((last_success_epoch + WINDOW_SECONDS))"
      log "window idle (${quota_used_percent}% used, source=$quota_source); self-cadence trigger not due until $(format_epoch "$next_self_epoch")"
      exit 0
    fi
  elif (( now_epoch < quota_reset_epoch )); then
    log "window active: ${quota_used_percent}% used; next reset $quota_reset_text (source=$quota_source)"
    exit 0
  elif (( last_success_epoch >= quota_reset_epoch )); then
    log "reset at $quota_reset_text already has a successful keeper trigger at $(format_epoch "$last_success_epoch"); nothing to do"
    exit 0
  else
    due=1
    due_reason="reset at $quota_reset_text has passed with no keeper trigger for it"
  fi
else
  log "WARN: $usage_status; falling back to own cadence"
  # No trustworthy reading at all: only our own state file is available.
  if (( last_success_epoch == 0 )); then
    log "no quota reading and no keeper baseline; refusing to guess when the window expired"
    exit 0
  fi
  fallback_reset_epoch="$((last_success_epoch + WINDOW_SECONDS))"
  if (( now_epoch < fallback_reset_epoch )); then
    log "no quota reading; fallback window active until $(format_epoch "$fallback_reset_epoch")"
    exit 0
  fi
  due=1
  due_reason="no quota reading and the fallback five-hour window from $(format_epoch "$last_success_epoch") has expired"
fi

if (( due == 1 )); then
  log "trigger due: $due_reason"
fi

codex_args=(
  exec
  --ephemeral
  --json
  --model "$KEEPER_MODEL"
  --config "model_reasoning_effort=\"$KEEPER_REASONING_EFFORT\""
  --config "openai_base_url=\"$CODEX_BASE_URL\""
  --sandbox read-only
  --cd "$KEEPER_WORKDIR"
  --skip-git-repo-check
  "$KEEPER_PROMPT"
)

if [[ "$DRY_RUN" == 1 || "$LIVE_TRIGGER_ENABLED" == 0 ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: no Codex request will be sent"
  else
    log "live trigger is disarmed by $DEFAULTS_FILE; no Codex request will be sent"
  fi
  log "would run: $CODEX_BIN ${codex_args[*]}"
  exit 0
fi

if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
  log "ERROR: no executable Codex CLI was found"
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
  log "ERROR: timeout command is required for a bounded live request"
  exit 1
fi

log "sending one live keeper request with model=$KEEPER_MODEL effort=$KEEPER_REASONING_EFFORT"
log "live command: $CODEX_BIN ${codex_args[*]}"

output_file="$(mktemp "$STATE_DIR/trigger-output.XXXXXX")"
cleanup_output() {
  rm -f -- "$output_file"
}
trap cleanup_output EXIT

if timeout "$EXEC_TIMEOUT_SECONDS" "$CODEX_BIN" "${codex_args[@]}" >"$output_file" 2>&1; then
  trigger_epoch="$(date +%s)"
  state_tmp="$(mktemp "$STATE_DIR/last_success.XXXXXX")"
  printf '%s\n' "$trigger_epoch" > "$state_tmp"
  chmod 600 "$state_tmp"
  mv -f -- "$state_tmp" "$LAST_SUCCESS_FILE"
  printf 'timestamp=%s source=%s reset=%s percent=%s model=%s effort=%s reason=%s\n' \
    "$trigger_epoch" "$quota_source" "$quota_reset_epoch" "$quota_used_percent" \
    "$KEEPER_MODEL" "$KEEPER_REASONING_EFFORT" "$due_reason" >> "$HISTORY_FILE"
  log "live keeper request succeeded at $(format_epoch "$trigger_epoch"); recorded timestamp"
  if [[ -s "$output_file" ]]; then
    log "Codex output tail:"
    tail -n 20 "$output_file"
  fi
  exit 0
else
  request_status=$?
fi

log "ERROR: live keeper request failed or timed out (exit=$request_status)"
if [[ -s "$output_file" ]]; then
  log "Codex failure output tail:"
  tail -n 40 "$output_file"
fi
exit "$request_status"
