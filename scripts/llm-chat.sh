#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF' >&2
Usage:
  llm-chat.sh chat "<prompt>"
  llm-chat.sh reset
  llm-chat.sh show
EOF
}

BASE_URL="${LLM_CHAT_BASE_URL:-http://nixos:11434}"
MODEL="${LLM_CHAT_MODEL:-qwen2.5:7b}"
STATE_FILE="${LLM_CHAT_STATE:-$HOME/.cache/homelab/llm-chat.json}"
MAX_TOKENS="${LLM_CHAT_MAX_TOKENS:-256}"
MAX_MESSAGES="${LLM_CHAT_MAX_MESSAGES:-40}"

init_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '{"model":"%s","messages":[]}\n' "$MODEL" >"$STATE_FILE"
}

show_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "[llm-chat] state not found: $STATE_FILE" >&2
    exit 1
  fi
  jq . "$STATE_FILE"
}

chat() {
  prompt="${1:-${PROMPT:-}}"
  if [ -z "$prompt" ]; then
    echo "[llm-chat] prompt is empty. Use PROMPT='...'" >&2
    exit 1
  fi

  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi

  req_file="$(mktemp "${TMPDIR:-/tmp}/llm-chat-req.XXXXXX.json")"
  resp_file="$(mktemp "${TMPDIR:-/tmp}/llm-chat-resp.XXXXXX.json")"
  state_tmp="${STATE_FILE}.tmp"
  trap 'rm -f "$req_file" "$resp_file" "$state_tmp"' EXIT INT TERM

  jq \
    --arg model "$MODEL" \
    --arg prompt "$prompt" \
    --argjson max_tokens "$MAX_TOKENS" \
    --argjson max_messages "$MAX_MESSAGES" \
    '
      .model = $model
      | (.messages // []) as $history
      | ($history + [{"role":"user","content":$prompt}]) as $msgs
      | {
          model: $model,
          stream: false,
          options: { num_predict: $max_tokens },
          messages: (if ($msgs|length) > $max_messages then $msgs[-$max_messages:] else $msgs end)
        }
    ' "$STATE_FILE" >"$req_file"

  http_code="$(
    curl --silent --show-error \
      "$BASE_URL/api/chat" \
      -H "Content-Type: application/json" \
      --data @"$req_file" \
      -o "$resp_file" \
      -w "%{http_code}"
  )"

  if [ "$http_code" != "200" ]; then
    body="$(cat "$resp_file")"
    echo "[llm-chat] request failed: HTTP $http_code" >&2
    echo "$body" >&2
    exit 1
  fi

  reply="$(jq -r '.message.content // ""' "$resp_file")"
  if [ -z "$reply" ]; then
    reply="$(jq -c . "$resp_file")"
  fi

  printf '%s\n' "$reply"

  jq \
    --arg model "$MODEL" \
    --arg prompt "$prompt" \
    --arg reply "$reply" \
    --argjson max_messages "$MAX_MESSAGES" \
    '
      .model = $model
      | (.messages // []) as $history
      | ($history + [{"role":"user","content":$prompt},{"role":"assistant","content":$reply}]) as $msgs
      | .messages = (if ($msgs|length) > $max_messages then $msgs[-$max_messages:] else $msgs end)
    ' "$STATE_FILE" >"$state_tmp"

  mv "$state_tmp" "$STATE_FILE"
}

cmd="${1:-}"
case "$cmd" in
  reset)
    init_state
    echo "[llm-chat] reset: $STATE_FILE"
    ;;
  show)
    show_state
    ;;
  chat)
    shift
    chat "$*"
    ;;
  *)
    usage
    exit 1
    ;;
esac
