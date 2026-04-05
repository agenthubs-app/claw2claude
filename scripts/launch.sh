#!/usr/bin/env bash
# claw2claude/scripts/launch.sh
#
# Usage:
#   launch.sh <project_path> discuss    "<prompt>"  # Discussion/planning mode (read-only)
#   launch.sh <project_path> execute    "<prompt>"  # Execution mode (auto-approve all permissions)
#   launch.sh <project_path> continue   "<prompt>"  # Resume the previous session
#   launch.sh <project_path> background "<prompt>"  # Run in background, return immediately

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${1:-}"
MODE="${2:-execute}"
PROMPT="${3:-}"

SESSION_FILE=".openclaw-claude-session.json"
TMPDIR_BASE="/tmp/claw2claude-$$"
TIMEOUT_SEC=1800  # 30 minutes

# ── Validate dependencies ────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "❌ claude command not found — please install Claude Code CLI" >&2
  exit 1
fi

# ── Validate MODE ────────────────────────────────────────────────
case "$MODE" in
  discuss|execute|continue|background) ;;
  *)
    echo "❌ Invalid mode: '$MODE' (valid values: discuss | execute | continue | background)" >&2
    exit 1
    ;;
esac

# ── Validate arguments ───────────────────────────────────────────
if [[ -z "$PROJECT_PATH" ]]; then
  echo "❌ Missing project path argument" >&2
  exit 1
fi
PROJECT_PATH="${PROJECT_PATH/#\~/$HOME}"

# ── Cleanup on exit ──────────────────────────────────────────────
cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT
mkdir -p "$TMPDIR_BASE"
SESSION_ID_FILE="$TMPDIR_BASE/session_id"

# ── Create / enter project directory ────────────────────────────
if [[ ! -d "$PROJECT_PATH" ]]; then
  mkdir -p "$PROJECT_PATH"
  echo "📁 Created project directory: $PROJECT_PATH" >&2
  cd "$PROJECT_PATH"
  git init -q
  echo "📦 Initialised Git repository" >&2
  echo ".openclaw-claude-session.json" >> .gitignore
  echo "📝 Added session file to .gitignore" >&2
else
  echo "📂 Using project directory: $PROJECT_PATH" >&2
  cd "$PROJECT_PATH"
  # Add session file to .gitignore if not already excluded
  # (covers both existing .gitignore and the case where none exists yet)
  if ! grep -qF ".openclaw-claude-session.json" .gitignore 2>/dev/null; then
    echo ".openclaw-claude-session.json" >> .gitignore
  fi
fi

# ── Check token health ───────────────────────────────────────────
python3 "$SKILL_DIR/scripts/check_token.py" || true

# ── Register project and print registry for AI reference ────────
PROJECT_NAME="$(basename "$PROJECT_PATH")"
python3 "$SKILL_DIR/scripts/projects.py" register "$PROJECT_PATH" "$PROJECT_NAME" > /dev/null
echo "── Registered projects ──" >&2
python3 "$SKILL_DIR/scripts/projects.py" list >&2
echo "─────────────────────────" >&2

# ── Read previous session state ──────────────────────────────────
LAST_SESSION_ID=""
LAST_MODE=""
if [[ -f "$SESSION_FILE" ]]; then
  LAST_SESSION_ID=$(python3 "$SKILL_DIR/scripts/read_session.py" "$SESSION_FILE" session_id)
  LAST_MODE=$(python3 "$SKILL_DIR/scripts/read_session.py" "$SESSION_FILE" mode)
fi

# ── Background mode: launch detached, return immediately ─────────
if [[ "$MODE" == "background" ]]; then
  if [[ -z "$PROMPT" ]]; then
    echo "❌ Background mode requires a prompt — no instruction provided" >&2
    exit 1
  fi

  BG_LOG="${PROJECT_PATH}/.claude-bg.log"
  echo "🚀 Launching Claude Code in background..." >&2
  echo "📋 Log: $BG_LOG" >&2

  # Background always runs as execute (discuss/continue not supported in detached mode)
  nohup bash "$0" "$PROJECT_PATH" execute "$PROMPT" > "$BG_LOG" 2>&1 &
  BG_PID=$!
  echo "🔧 PID=$BG_PID" >&2

  # Start heartbeat to monitor the background process
  nohup python3 "$SKILL_DIR/scripts/heartbeat.py" \
    --pid "$BG_PID" \
    --log "$BG_LOG" \
    --project "$PROJECT_NAME" \
    > "${BG_LOG%.log}-heartbeat.log" 2>&1 &

  echo "✅ Background task started (PID=$BG_PID) — you will be notified when it completes" >&2
  exit 0
fi

# ── Determine effective mode (used for session label) ────────────
EFFECTIVE_MODE="$MODE"
if [[ "$MODE" == "continue" ]]; then
  EFFECTIVE_MODE="${LAST_MODE:-execute}"
fi
SESSION_LABEL="${PROJECT_NAME}:${EFFECTIVE_MODE}"

# ── Build Claude arguments ───────────────────────────────────────
CLAUDE_ARGS=(--print --output-format stream-json --verbose --name "$SESSION_LABEL")

case "$MODE" in
  discuss)
    CLAUDE_ARGS+=(--dangerously-skip-permissions)
    echo "💬 Discuss mode" >&2
    ;;

  execute)
    CLAUDE_ARGS+=(--dangerously-skip-permissions)
    echo "⚡ Execute mode (all permission prompts skipped)" >&2
    # Auto-resume only when transitioning from a prior discuss session
    # (execute→execute starts fresh; only discuss→execute carries context)
    if [[ -n "$LAST_SESSION_ID" && "$LAST_MODE" == "discuss" ]]; then
      CLAUDE_ARGS+=(--resume "$LAST_SESSION_ID")
      echo "🔗 Carrying over discussion context (session: ${LAST_SESSION_ID:0:8}...)" >&2
    fi
    ;;

  continue)
    if [[ -n "$LAST_SESSION_ID" ]]; then
      CLAUDE_ARGS+=(--resume "$LAST_SESSION_ID")
      CLAUDE_ARGS+=(--dangerously-skip-permissions)
      echo "🔄 Resuming ${LAST_MODE:-execute} session (${LAST_SESSION_ID:0:8}...)" >&2
    else
      CLAUDE_ARGS+=(--dangerously-skip-permissions)
      echo "⚠️  No previous session found — starting a new execute session" >&2
    fi
    ;;
esac

# Appended to every prompt — instructs Claude to end with a structured chat summary
SUMMARY_INSTRUCTION='

---
IMPORTANT: At the very end of your response, write a section in this exact format:

---CHAT_SUMMARY_START---
(a concise summary in ≤400 words of the key points, questions, or decisions from this session — written to be sent directly to the user in a chat message, no code blocks)
---CHAT_SUMMARY_END---'

# ── Append prompt ────────────────────────────────────────────────
if [[ -n "$PROMPT" ]]; then
  # Prompt provided: pass it directly. Uses --resume (set above) to carry prior context.
  CLAUDE_ARGS+=("${PROMPT}${SUMMARY_INSTRUCTION}")
elif [[ "$MODE" == "continue" ]]; then
  if [[ -n "$LAST_SESSION_ID" ]]; then
    # No new prompt: use --continue to restore the full prior conversation interactively.
    # Rebuilds args from scratch because --continue is mutually exclusive with --resume.
    CLAUDE_ARGS=(--print --output-format stream-json --verbose --name "$SESSION_LABEL" --continue --dangerously-skip-permissions)
  else
    # No previous session and no new prompt — nothing to continue
    echo "⚠️  Cannot continue: no previous session exists for this project and no new instruction was provided" >&2
    echo "💡 Please provide an instruction, or use execute mode to start a new task" >&2
    exit 1
  fi
fi

# ── Launch Claude ────────────────────────────────────────────────
echo "🤖 Starting Claude Code..." >&2
echo "📍 $PROJECT_PATH" >&2
echo "─────────────────────────────────" >&2

# Use timeout if available
if command -v timeout &>/dev/null; then
  CMD_PREFIX=(timeout "$TIMEOUT_SEC")
elif command -v gtimeout &>/dev/null; then
  CMD_PREFIX=(gtimeout "$TIMEOUT_SEC")
else
  CMD_PREFIX=()
fi

# Full output is saved to this log file; stdout only returns a summary
RUN_LOG="${PROJECT_PATH}/.claude-last-run.log"

# Run Claude and pipe output through the stream parser
set +e
if [ ${#CMD_PREFIX[@]} -gt 0 ]; then
  "${CMD_PREFIX[@]}" claude "${CLAUDE_ARGS[@]}" 2>&1 | python3 -u "$SKILL_DIR/scripts/parse_stream.py" \
    --mode "$EFFECTIVE_MODE" \
    --project "$PROJECT_NAME" \
    --session-out "$SESSION_ID_FILE" \
    --log-out "$RUN_LOG"
else
  claude "${CLAUDE_ARGS[@]}" 2>&1 | python3 -u "$SKILL_DIR/scripts/parse_stream.py" \
    --mode "$EFFECTIVE_MODE" \
    --project "$PROJECT_NAME" \
    --session-out "$SESSION_ID_FILE" \
    --log-out "$RUN_LOG"
fi
PIPE_STATUS=("${PIPESTATUS[@]}")
set -e

CLAUDE_RAW_EXIT=${PIPE_STATUS[0]}
PARSER_EXIT=${PIPE_STATUS[1]}

if [[ "$CLAUDE_RAW_EXIT" -eq 124 ]]; then
  echo "⏰ Claude timed out (>${TIMEOUT_SEC}s) — task was aborted" >&2
fi

# ── Save session state (skip on timeout to avoid saving partial state) ──
if [[ "$CLAUDE_RAW_EXIT" -ne 124 ]] && [[ -f "$SESSION_ID_FILE" ]]; then
  NEW_SESSION_ID=$(cat "$SESSION_ID_FILE")
  if [[ -n "$NEW_SESSION_ID" ]]; then
    python3 "$SKILL_DIR/scripts/write_session.py" \
      "$SESSION_FILE" "$NEW_SESSION_ID" "$EFFECTIVE_MODE" "$PROJECT_PATH"
    echo "💾 Session saved (${NEW_SESSION_ID:0:8}...)" >&2
  fi
fi

[[ "$CLAUDE_RAW_EXIT" -eq 0 && "$PARSER_EXIT" -eq 0 ]] && exit 0 || exit 1
