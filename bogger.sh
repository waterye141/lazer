#!/bin/bash
set -e

OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GROQ_API_KEY=${GROQ_API_KEY:-}
OPENROUTER_MODEL=${OPENROUTER_MODEL:-openrouter/free}
GROQ_MODEL=${GROQ_MODEL:-openai/gpt-oss-120b}
OPENROUTER_API_URL=${OPENROUTER_API_URL:-https://openrouter.ai/api/v1/chat/completions}
GROQ_API_URL=${GROQ_API_URL:-https://api.groq.com/openai/v1/chat/completions}
NONINTERACTIVE=0
SERVICE_ENV_FILE=${BOGGER_ENV_FILE:-/etc/bogger/bogger.env}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ "${1:-}" == "--service" ]]; then
  NONINTERACTIVE=1
  shift
fi
LOG_FILE=${1:-${LOG_FILE:-}}

load_configuration() {
  if [[ -z "$OPENROUTER_API_KEY" && -f .env ]]; then
    OPENROUTER_API_KEY=$(cat .env)
  fi

  if [[ -f "$SERVICE_ENV_FILE" ]]; then
    source "$SERVICE_ENV_FILE"
  fi
}

resolve_log_file() {
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE=$(sudo nginx -T 2>/dev/null |
      grep -oP '(?<=access_log\s)\S+' |
      head -1)
  fi

  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/log/nginx/access.log"
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    if ((NONINTERACTIVE)); then
      echo "Error: unable to resolve an access log in non-interactive mode" >&2
      exit 1
    fi
    echo $'\n'$"Log file not found, please provide the log file path: "
    read -r LOG_FILE
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    echo "Error: access log not found at '$LOG_FILE'" >&2
    echo "Usage: $0 /path/to/access.log" >&2
    exit 1
  fi

  local FIRST_LINE
  FIRST_LINE=$(grep -m1 '[^[:space:]]' "$LOG_FILE" 2>/dev/null || true)
  if [[ -z "$FIRST_LINE" ]]; then
    echo "Error: file is empty" >&2
    exit 1
  fi

  if ! echo "$FIRST_LINE" | grep -qP '^\S+\s+\S+\s+\S+\s+\[.+?\]\s+"[A-Z]+\s+\S+\s+HTTP/\d\.\d"\s+\d{3}\s+\S+'; then
    echo "Error: '$LOG_FILE' does not look like an nginx access log" >&2
    echo "  First line: $FIRST_LINE" >&2
    exit 1
  fi
}

stats_summary() {
  local COUNT
  COUNT=$2
  echo -e "\nTop $COUNT IP addresses with the most requests:"
  awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$COUNT"

  echo -e "\nTop $COUNT most requested paths:"
  awk '{print $7}' "$LOG_FILE" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$COUNT"

  echo -e "\nTop $COUNT response status codes:"
  grep -oE ' [0-9][0-9][0-9] ' "$LOG_FILE" | sort | uniq -c | sort -nr | head -n "$COUNT" | awk '{printf "%s - %d Requests\n", $2, $1}'

  echo -e "\nTop $COUNT user agents:"
  awk -F'"' '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -nr | head -n "$COUNT" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print "-",$1,"requests" }'
  printf "\n"

}

display() {
  resolve_log_file
  echo "How many lines do you want to display?:"
  read -r COUNT
  clear
  stats_summary "$LOG_FILE" "$COUNT"

}

extract_content() {
  jq -r '.choices[0].message.content // empty'
}

build_request() {
  local model=$1
  local system_prompt=$2
  local user_prompt=$3
  jq -n \
    --arg model "$model" \
    --arg system "$system_prompt" \
    --arg user "$user_prompt" \
    '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], temperature: 0.2, max_tokens: 6000}'
}

request_provider() {
  local provider=$1
  local api_key
  local api_url
  local model
  case "$provider" in
  openrouter)
    api_key=$OPENROUTER_API_KEY
    api_url=$OPENROUTER_API_URL
    model=$OPENROUTER_MODEL
    ;;
  groq)
    api_key=$GROQ_API_KEY
    api_url=$GROQ_API_URL
    model=$GROQ_MODEL
    ;;
  *)
    echo "Error: unsupported provider '$provider'" >&2
    return 1
    ;;
  esac

  if [[ -z "$api_key" ]]; then
    echo "Provider '$provider' is not configured" >&2
    return 1
  fi

  local raw_response
  if ! raw_response=$(
    curl -sS --connect-timeout 15 --max-time 120 \
      -w $'\n%{http_code}' \
      "$api_url" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $api_key" \
      -d "$REQUEST_BODY"
  ); then
    echo "Provider '$provider' request failed" >&2
    return 1
  fi

  local http_code=${raw_response##*$'\n'}
  local response=${raw_response%$'\n'*}
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "Provider '$provider' returned HTTP $http_code" >&2
    return 1
  fi

  local content
  content=$(printf '%s' "$response" | extract_content)
  if [[ -z "$content" ]]; then
    echo "Provider '$provider' returned no analysis content" >&2
    return 1
  fi
  if ! printf '%s' "$content" | jq -e 'type == "object" and (.anomaly | type == "boolean") and (.findings | type == "string")' >/dev/null 2>&1; then
    echo "Provider '$provider' returned an invalid analysis schema" >&2
    return 1
  fi
  printf '%s' "$content"
}

request_analysis() {
  resolve_log_file
  local response
  local summary
  local recent_lines
  summary=$(stats_summary "$LOG_FILE" 10)
  recent_lines=$(tail -n 30 "$LOG_FILE")
  local system_prompt='Analyze the Nginx access log for anomalies. Return only valid JSON with this schema: {"anomaly": boolean, "findings": string}. Set anomaly to true only when the log contains a meaningful anomaly.'
  local user_prompt
  user_prompt=$(printf 'Nginx summary for %s:\n%s\n\nLast 30 raw lines:\n%s\n\nTask: identify anomalies.' "$LOG_FILE" "$summary" "$recent_lines")
  REQUEST_BODY=$(build_request "$OPENROUTER_MODEL" "$system_prompt" "$user_prompt")

  if response=$(request_provider openrouter); then
    printf '%s' "$response"
    return 0
  fi

  if [[ -z "$GROQ_API_KEY" ]]; then
    echo "Error: OpenRouter failed and GROQ_API_KEY is not configured" >&2
    return 1
  fi

  REQUEST_BODY=$(build_request "$GROQ_MODEL" "$system_prompt" "$user_prompt")
  if response=$(request_provider groq); then
    printf '%s' "$response"
    return 0
  fi
  echo "Error: both OpenRouter and Groq analysis requests failed" >&2
  return 1
}

analyse() {
  resolve_log_file
  clear
  sleep 1
  local final_response
  final_response=$(request_analysis) || {
    echo "Error, sending request." >&2
    return 1
  }
  if ! printf '%s' "$final_response" | jq empty >/dev/null 2>&1; then
    echo "Error: analysis response was not valid JSON" >&2
    return 1
  fi
  printf '%s\n' "$final_response" | jq -r '.findings // empty'
}

send_notification() {
  local findings=$1
  local host_name=${HOSTNAME:-}
  if [[ -z "$host_name" ]]; then
    host_name=$(hostname 2>/dev/null || printf 'unknown-host')
  fi
  if [[ -z "${BOGGER_EMAIL_RECIPIENT:-}" ]]; then
    echo "Error: BOGGER_EMAIL_RECIPIENT is not configured" >&2
    return 1
  fi
  if [[ -z "${BOGGER_MAIL_COMMAND:-}" ]]; then
    echo "Error: BOGGER_MAIL_COMMAND is not configured" >&2
    return 1
  fi
  printf '%s\n' "$findings" | "$BOGGER_MAIL_COMMAND" \
    -s "Bogger anomaly detected on $host_name" "$BOGGER_EMAIL_RECIPIENT"
}

service_analysis() {
  NONINTERACTIVE=1
  if [[ -z "$OPENROUTER_API_KEY" ]]; then
    echo "Error: OPENROUTER_API_KEY is not configured" >&2
    return 1
  fi
  local result
  result=$(request_analysis) || return 1
  if [[ "$(printf '%s' "$result" | jq -r '.anomaly')" == "true" ]]; then
    local findings
    findings=$(printf '%s' "$result" | jq -r '.findings')
    echo "Anomaly detected: $findings"
    send_notification "$findings"
  else
    echo "No anomaly detected"
  fi
}

setup() {
  sudo mkdir -p /usr/share/bogger/systemd
  sudo cp "$SCRIPT_DIR/bogger.sh" /usr/bin/bogger
  sudo cp "$SCRIPT_DIR/systemd/bogger.service" "$SCRIPT_DIR/systemd/bogger.timer" "$SCRIPT_DIR/systemd/bogger.env.example" /usr/share/bogger/systemd/
}

remove() {
  if [[ -f /etc/systemd/system/bogger.timer ]]; then
    sudo systemctl disable --now bogger.timer || true
  fi
  sudo rm -f /etc/systemd/system/bogger.timer /etc/systemd/system/bogger.service
  sudo systemctl daemon-reload
  sudo rm /usr/bin/bogger
  sudo rm -rf /usr/share/bogger
}

install_systemd_service() {
  local unit_source_dir="$SCRIPT_DIR/systemd"
  if [[ ! -d "$unit_source_dir" ]]; then
    unit_source_dir="/usr/share/bogger/systemd"
  fi
  if [[ ! -d "$unit_source_dir" ]]; then
    echo "Error: systemd templates are not available at '$unit_source_dir'" >&2
    return 1
  fi
  sudo mkdir -p /etc/bogger
  sudo cp "$SCRIPT_DIR/bogger.sh" /usr/bin/bogger
  sudo cp "$unit_source_dir/bogger.service" /etc/systemd/system/bogger.service
  sudo cp "$unit_source_dir/bogger.timer" /etc/systemd/system/bogger.timer
  if [[ ! -f /etc/bogger/bogger.env ]]; then
    sudo cp "$unit_source_dir/bogger.env.example" /etc/bogger/bogger.env
    sudo chmod 600 /etc/bogger/bogger.env
    echo "Edit /etc/bogger/bogger.env before starting the timer."
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now bogger.timer
}

welcome() {
  echo "
▀█████████▄   ▄██████▄     ▄██████▄     ▄██████▄     ▄████████    ▄████████ 
  ███    ███ ███    ███   ███    ███   ███    ███   ███    ███   ███    ███ 
  ███    ███ ███    ███   ███    █▀    ███    █▀    ███    █▀    ███    ███ 
 ▄███▄▄▄██▀  ███    ███  ▄███         ▄███         ▄███▄▄▄      ▄███▄▄▄▄██▀ 
▀▀███▀▀▀██▄  ███    ███ ▀▀███ ████▄  ▀▀███ ████▄  ▀▀███▀▀▀     ▀▀███▀▀▀▀▀   
  ███    ██▄ ███    ███   ███    ███   ███    ███   ███    █▄  ▀███████████ 
  ███    ███ ███    ███   ███    ███   ███    ███   ███    ███   ███    ███ 
▄█████████▀   ▀██████▀    ████████▀    ████████▀    ██████████   ███    ███ 
                                                                 ███    ███
	"
  echo $'\n'$"Enter a selection from the folowing list..."
  echo "1 - Install bogger to PATH"
  echo "2 - Raw analysis"
  echo "3 - Get a summary regarding the logs read"
  echo "4 - Install systemd service to notify on anomalies"
  echo "5 - Remove bogger from your system"
  read -r selection
  case $selection in
  1)
    setup
    ;;
  2)
    display
    ;;
  3)
    analyse
    ;;
  4)
    install_systemd_service
    ;;
  5)
    remove
    ;;
  *)
    echo "Invalid selection try again..."
    sleep 1
    clear
    welcome
    ;;
  esac
}

load_configuration

if ((NONINTERACTIVE)); then
  service_analysis
  exit $?
fi

welcome
