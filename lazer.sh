#!/bin/bash
set -e

OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GROQ_API_KEY=${GROQ_API_KEY:-}
OPENROUTER_MODEL=${OPENROUTER_MODEL:-}
GROQ_MODEL=${GROQ_MODEL:-}
OPENROUTER_API_URL=${OPENROUTER_API_URL:-}
GROQ_API_URL=${GROQ_API_URL:-}
NONINTERACTIVE=0
SERVICE_ENV_FILE=${LAZER_ENV_FILE:-/etc/lazer/lazer.env}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_TYPE=${LAZER_SOURCE:-}
INPUT_FILE=${LAZER_INPUT_FILE:-}
JOURNALCTL_ARGS=${LAZER_JOURNALCTL_ARGS:-}
RECORDS_FILE=
CLI_SOURCE=
CLI_INPUT_FILE=
CLI_INPUT_SELECTION=0
CLI_ACTION=
PARSER_FILE="$SCRIPT_DIR/parsers.sh"
[[ -f "$PARSER_FILE" ]] || PARSER_FILE="/usr/share/lazer/parsers.sh"
COMPLETION_DIR="$SCRIPT_DIR/completions"
[[ -d "$COMPLETION_DIR" ]] || COMPLETION_DIR="/usr/share/lazer/completions"

error() {
  echo "Error: $*" >&2
  return 1
}

require_option_value() {
  local option=$1
  local value=${2:-}
  if [[ -z "$value" || "$value" == --* ]]; then
    error "$option requires a value"
    return 1
  fi
}

validate_source() {
  case "$1" in
  nginx|apache|ssh|systemd_journal|haproxy|docker|generic)
    ;;
  *)
    error "unsupported source '$1'; choose nginx, apache, ssh, systemd_journal, haproxy, docker, or generic"
    return 1
    ;;
  esac
}
# shellcheck disable=SC1090
source "$PARSER_FILE"
if [[ "${1:-}" == "--service" ]]; then
  NONINTERACTIVE=1
  shift
fi
if [[ -n "${1:-}" && "${1:0:2}" != "--" ]]; then
  CLI_INPUT_FILE=$1
  CLI_INPUT_SELECTION=1
  shift
fi

load_configuration() {
  if [[ -f .env ]]; then
    local env_openrouter_api_key=$OPENROUTER_API_KEY
    local env_groq_api_key=$GROQ_API_KEY
    local env_openrouter_model=$OPENROUTER_MODEL
    local env_groq_model=$GROQ_MODEL
    local env_openrouter_api_url=$OPENROUTER_API_URL
    local env_groq_api_url=$GROQ_API_URL
    local env_source_type=$SOURCE_TYPE
    local env_input_file=$INPUT_FILE
    local env_journalctl_args=$JOURNALCTL_ARGS
    local env_email_recipient=${LAZER_EMAIL_RECIPIENT:-}
    local env_mail_command=${LAZER_MAIL_COMMAND:-}
    local env_log_file=${LOG_FILE:-}
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' .env; then
      set -a
      # shellcheck disable=SC1091
      source .env
      set +a
    elif [[ -z "$OPENROUTER_API_KEY" ]]; then
      OPENROUTER_API_KEY=$(sed -n 's/^[[:space:]]*//; /^[^#[:space:]]/p; q' .env)
    fi
    if [[ -n "$env_openrouter_api_key" ]]; then OPENROUTER_API_KEY=$env_openrouter_api_key; fi
    if [[ -n "$env_groq_api_key" ]]; then GROQ_API_KEY=$env_groq_api_key; fi
    if [[ -n "$env_openrouter_model" ]]; then OPENROUTER_MODEL=$env_openrouter_model; fi
    if [[ -n "$env_groq_model" ]]; then GROQ_MODEL=$env_groq_model; fi
    if [[ -n "$env_openrouter_api_url" ]]; then OPENROUTER_API_URL=$env_openrouter_api_url; fi
    if [[ -n "$env_groq_api_url" ]]; then GROQ_API_URL=$env_groq_api_url; fi
    if [[ -n "$env_source_type" ]]; then SOURCE_TYPE=$env_source_type; fi
    if [[ -n "$env_input_file" ]]; then INPUT_FILE=$env_input_file; fi
    if [[ -n "$env_journalctl_args" ]]; then JOURNALCTL_ARGS=$env_journalctl_args; fi
    if [[ -n "$env_email_recipient" ]]; then LAZER_EMAIL_RECIPIENT=$env_email_recipient; fi
    if [[ -n "$env_mail_command" ]]; then LAZER_MAIL_COMMAND=$env_mail_command; fi
    if [[ -n "$env_log_file" ]]; then LOG_FILE=$env_log_file; fi
  fi

  if [[ -f "$SERVICE_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SERVICE_ENV_FILE"
  fi
  SOURCE_TYPE=${LAZER_SOURCE:-$SOURCE_TYPE}
  INPUT_FILE=${LAZER_INPUT_FILE:-${LOG_FILE:-$INPUT_FILE}}
  OPENROUTER_MODEL=${OPENROUTER_MODEL:-openrouter/free}
  GROQ_MODEL=${GROQ_MODEL:-openai/gpt-oss-120b}
  OPENROUTER_API_URL=${OPENROUTER_API_URL:-https://openrouter.ai/api/v1/chat/completions}
  GROQ_API_URL=${GROQ_API_URL:-https://api.groq.com/openai/v1/chat/completions}
  SOURCE_TYPE=${SOURCE_TYPE:-nginx}
}

parse_cli_arguments() {
  while (($#)); do
    case "$1" in
    --stats)
      if [[ -n "$CLI_ACTION" && "$CLI_ACTION" != stats ]]; then
        echo "Error: --stats and --analyze cannot be used together" >&2
        return 1
      fi
      CLI_ACTION=stats
      shift
      ;;
    --analyze)
      if [[ -n "$CLI_ACTION" && "$CLI_ACTION" != analyze ]]; then
        echo "Error: --stats and --analyze cannot be used together" >&2
        return 1
      fi
      CLI_ACTION=analyze
      shift
      ;;
    --source)
      require_option_value "--source" "${2:-}" || return 1
      CLI_SOURCE=${2:-}
      CLI_INPUT_SELECTION=1
      shift 2
      ;;
    --file)
      require_option_value "--file" "${2:-}" || return 1
      CLI_INPUT_FILE=${2:-}
      CLI_INPUT_SELECTION=1
      shift 2
      ;;
    --unit)
      require_option_value "--unit" "${2:-}" || return 1
      JOURNALCTL_ARGS+=" -u ${2:-}"
      shift 2
      ;;
    --since)
      require_option_value "--since" "${2:-}" || return 1
      JOURNALCTL_ARGS+=" --since ${2:-}"
      shift 2
      ;;
    --until)
      require_option_value "--until" "${2:-}" || return 1
      JOURNALCTL_ARGS+=" --until ${2:-}"
      shift 2
      ;;
    --help)
      cat <<'EOF'
Usage: lazer.sh [--stats|--analyze] [--service] [--source SOURCE] [--file PATH]

Sources: nginx, apache, ssh, systemd_journal, haproxy, docker, generic
Journal options: --unit UNIT, --since TIME, --until TIME
Actions: --stats for local statistics, --analyze for AI anomaly analysis
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      return 1
      ;;
    esac
  done
  if [[ -n "$CLI_SOURCE" ]]; then
    validate_source "$CLI_SOURCE" || return 1
    SOURCE_TYPE=$CLI_SOURCE
  fi
  if [[ -n "$CLI_INPUT_FILE" ]]; then
    INPUT_FILE=$CLI_INPUT_FILE
  fi
  if [[ "$SOURCE_TYPE" == systemd_journal && -n "$CLI_INPUT_FILE" ]]; then
    error "--file cannot be used with systemd_journal"
    return 1
  fi
  validate_source "$SOURCE_TYPE" || return 1
}

resolve_input() {
  if [[ "$SOURCE_TYPE" == nginx && -z "$INPUT_FILE" ]]; then
    INPUT_FILE=$(sudo nginx -T 2>/dev/null |
      grep -oP '(?<=access_log\s)\S+' |
      head -1)
  fi

  if [[ "$SOURCE_TYPE" == nginx && -z "$INPUT_FILE" ]]; then
    INPUT_FILE="/var/log/nginx/access.log"
  fi

  if [[ "$SOURCE_TYPE" == systemd_journal ]]; then
    return 0
  fi

  if [[ ! -f "$INPUT_FILE" ]]; then
    if ((NONINTERACTIVE)); then
      echo "Error: unable to resolve a '$SOURCE_TYPE' log in non-interactive mode" >&2
      exit 1
    fi
    echo $'\n'"Log file not found, please provide the $SOURCE_TYPE log file path: "
    if ! read -r INPUT_FILE || [[ -z "$INPUT_FILE" ]]; then
      error "a log file path is required"
      exit 1
    fi
  fi

  if [[ ! -f "$INPUT_FILE" ]]; then
    error "$SOURCE_TYPE log not found at '$INPUT_FILE'"
    echo "Usage: $0 --source $SOURCE_TYPE --file /path/to/log" >&2
    exit 1
  fi
}

prepare_records() {
  rm -f "$RECORDS_FILE"
  RECORDS_FILE=$(mktemp)
  if ! parse_input_to_records "$SOURCE_TYPE" "$INPUT_FILE" "$RECORDS_FILE"; then
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
    return 1
  fi
}

stats_summary() {
  local COUNT
  local records_file=$1
  COUNT=$2
  if [[ "$SOURCE_TYPE" == nginx ]]; then
    echo -e "\nTop $COUNT IP addresses with the most requests:"
    awk '{print $1}' "$records_file" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$COUNT"

    echo -e "\nTop $COUNT most requested paths:"
    awk '{print $7}' "$records_file" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$COUNT"

    echo -e "\nTop $COUNT response status codes:"
    grep -oE ' [0-9][0-9][0-9] ' "$records_file" | sort | uniq -c | sort -nr | head -n "$COUNT" | awk '{printf "%s - %d Requests\n", $2, $1}'

    echo -e "\nTop $COUNT user agents:"
    awk -F'"' '{print $6}' "$records_file" | sort | uniq -c | sort -nr | head -n "$COUNT" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print "-",$1,"requests" }'
    printf "\n"
    return 0
  fi

  echo -e "\nSources:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .source] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) records"
  ' "$records_file"

  echo -e "\nSeverities:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .severity] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) records"
  ' "$records_file"

  echo -e "\nTop client IPs:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .fields.ip? // "N/A"] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) requests"
  ' "$records_file"

  echo -e "\nTop request paths:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .fields.path? // "N/A"] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) requests"
  ' "$records_file"

  echo -e "\nTop response status codes:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .fields.status? // "N/A"] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) requests"
  ' "$records_file"

  echo -e "\nTop user agents:"
  jq -sr --argjson count "$COUNT" '
    [.[] | .fields.user_agent? // "N/A"] | group_by(.) | map({name: .[0], count: length}) |
    sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) requests"
  ' "$records_file"
  printf "\n"
}

print_record_group() {
  local records_file=$1
  local count=$2
  local label=$3
  local expression=$4
  local suffix=$5
  echo "$label:"
  jq -sr --argjson count "$count" "$expression
    | group_by(.)
    | map({name: .[0], count: length})
    | sort_by(-.count)
    | .[:\$count][]
    | \"\\(.name) - \\(.count) $suffix\"
  " "$records_file"
}

specialized_summary() {
  local records_file=$1
  local count=$2

  case "$SOURCE_TYPE" in
  nginx|apache)
    echo -e "\nHTTP-specific indicators:"
    print_record_group "$records_file" "$count" "Status classes" '[.[] | .fields.status_class? // "N/A"]' "responses"
    print_record_group "$records_file" "$count" "Methods" '[.[] | .fields.method? // "N/A"]' "requests"
    print_record_group "$records_file" "$count" "Referrers" '[.[] | .fields.referrer? // "N/A"]' "requests"
    ;;
  docker)
    echo -e "\nDocker-specific indicators:"
    print_record_group "$records_file" "$count" "Streams" '[.[] | .fields.stream? // "N/A"]' "records"
    print_record_group "$records_file" "$count" "Events" '[.[] | .fields.event? // "N/A"]' "events"
    print_record_group "$records_file" "$count" "Status classes" '[.[] | .fields.status_class? // "N/A"]' "records"
    if [[ -n "${LAZER_DOCKER_CONTAINER:-}" ]]; then
      echo "Docker runtime metadata:"
      if command -v docker >/dev/null 2>&1; then
        if ! docker inspect --format 'name={{.Name}} image={{.Config.Image}} status={{.State.Status}} restart_count={{.RestartCount}}' "$LAZER_DOCKER_CONTAINER" 2>/dev/null; then
          echo "runtime metadata unavailable for '$LAZER_DOCKER_CONTAINER'"
        fi
        if ! docker stats --no-stream --format 'cpu={{.CPUPerc}} memory={{.MemUsage}} memory_percent={{.MemPerc}} network={{.NetIO}} block_io={{.BlockIO}} pids={{.PIDs}}' "$LAZER_DOCKER_CONTAINER" 2>/dev/null; then
          echo "runtime statistics unavailable for '$LAZER_DOCKER_CONTAINER'"
        fi
      else
        echo "docker CLI is unavailable; showing log data only"
      fi
    fi
    ;;
  ssh)
    echo -e "\nSSH/authentication indicators:"
    print_record_group "$records_file" "$count" "Events" '[.[] | .fields.event? // "N/A"]' "records"
    print_record_group "$records_file" "$count" "Usernames" '[.[] | .fields.username? // "N/A"]' "attempts"
    print_record_group "$records_file" "$count" "Source IPs" '[.[] | .fields.ip? // "N/A"]' "attempts"
    ;;
  systemd_journal)
    echo -e "\nsystemd journal indicators:"
    print_record_group "$records_file" "$count" "Units" '[.[] | .fields.unit? // "N/A"]' "records"
    print_record_group "$records_file" "$count" "Events" '[.[] | .fields.event? // "N/A"]' "events"
    print_record_group "$records_file" "$count" "Severities" '[.[] | .severity]' "records"
    ;;
  haproxy)
    echo -e "\nHAProxy indicators:"
    print_record_group "$records_file" "$count" "Backends" '[.[] | .fields.backend? // "N/A"]' "requests"
    print_record_group "$records_file" "$count" "Termination states" '[.[] | .fields.termination_state? // "N/A"]' "requests"
    print_record_group "$records_file" "$count" "Statuses" '[.[] | .fields.status? // "N/A"]' "responses"
    ;;
  generic)
    echo -e "\nApplication log indicators:"
    jq -sr --argjson count "$count" '
      [.[] | .severity] | group_by(.) | map({name: .[0], count: length}) |
      sort_by(-.count) | .[:$count][] | "\(.name) - \(.count) records"
    ' "$records_file"
    ;;
  esac
}

display() {
  resolve_input
  echo "How many lines do you want to display?:"
  if ! read -r COUNT || [[ ! "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    error "the number of results must be a positive integer"
    return 1
  fi
  clear
  if [[ "$SOURCE_TYPE" == nginx ]]; then
    stats_summary "$INPUT_FILE" "$COUNT"
    prepare_records
    specialized_summary "$RECORDS_FILE" "$COUNT"
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
  else
    prepare_records
    stats_summary "$RECORDS_FILE" "$COUNT"
    specialized_summary "$RECORDS_FILE" "$COUNT"
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
  fi

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
  resolve_input
  local response
  local summary
  local recent_lines
  if [[ "$SOURCE_TYPE" == nginx ]]; then
    summary=$(stats_summary "$INPUT_FILE" 10)
    prepare_records
    summary+=$'\n'"$(specialized_summary "$RECORDS_FILE" 10)"
    recent_lines=$(tail -n 30 "$INPUT_FILE")
  else
    prepare_records
    summary=$(stats_summary "$RECORDS_FILE" 10)
    summary+=$'\n'"$(specialized_summary "$RECORDS_FILE" 10)"
    recent_lines=$(tail -n 30 "$RECORDS_FILE")
  fi
  local system_prompt='Analyze server log records for anomalies. Return only valid JSON with this schema: {"anomaly": boolean, "findings": string}. Set anomaly to true only when the records contain a meaningful anomaly.'
  local user_prompt
  user_prompt=$(printf '%s summary for %s:\n%s\n\nLast 30 normalized records:\n%s\n\nTask: identify anomalies.' "$SOURCE_TYPE" "${INPUT_FILE:-system journal}" "$summary" "$recent_lines")
  REQUEST_BODY=$(build_request "$OPENROUTER_MODEL" "$system_prompt" "$user_prompt")

  if response=$(request_provider openrouter); then
    printf '%s' "$response"
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
    return 0
  fi

  if [[ -z "$GROQ_API_KEY" ]]; then
    echo "Error: OpenRouter failed and GROQ_API_KEY is not configured" >&2
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
    return 1
  fi

  REQUEST_BODY=$(build_request "$GROQ_MODEL" "$system_prompt" "$user_prompt")
  if response=$(request_provider groq); then
    printf '%s' "$response"
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=
    return 0
  fi
  rm -f "$RECORDS_FILE"
  RECORDS_FILE=
  echo "Error: both OpenRouter and Groq analysis requests failed" >&2
  return 1
}

analyse() {
  resolve_input
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

select_action() {
  local action_selection
  echo
  echo "Choose an action:"
  echo "1 - View local statistics"
  echo "2 - Run AI anomaly analysis"
  if ! read -r action_selection; then
    error "an action selection is required"
    return 1
  fi
  case "$action_selection" in
  1)
    CLI_ACTION=stats
    ;;
  2)
    CLI_ACTION=analyze
    ;;
  *)
    echo "Invalid action selection." >&2
    return 1
    ;;
  esac
}

select_service() {
  local service_selection
  echo
  echo "Select the service whose logs you want to analyze:"
  echo "1 - Nginx"
  echo "2 - Apache"
  echo "3 - SSH/authentication"
  echo "4 - systemd journal"
  echo "5 - HAProxy"
  echo "6 - Docker"
  echo "7 - Generic application log"
  if ! read -r service_selection; then
    error "a service selection is required"
    return 1
  fi

  case "$service_selection" in
  1)
    SOURCE_TYPE=nginx
    echo "Log file path (leave blank to auto-detect Nginx access logs):"
    read -r INPUT_FILE
    ;;
  2)
    SOURCE_TYPE=apache
    echo "Apache log file path:"
    read -r INPUT_FILE
    ;;
  3)
    SOURCE_TYPE=ssh
    echo "SSH/authentication log file path:"
    read -r INPUT_FILE
    ;;
  4)
    SOURCE_TYPE=systemd_journal
    INPUT_FILE=
    echo "Optional journalctl filters (for example: --unit ssh.service --since today):"
    read -r JOURNALCTL_ARGS
    ;;
  5)
    SOURCE_TYPE=haproxy
    echo "HAProxy log file path:"
    read -r INPUT_FILE
    ;;
  6)
    SOURCE_TYPE=docker
    echo "Docker JSON log file path:"
    read -r INPUT_FILE
    ;;
  7)
    SOURCE_TYPE=generic
    echo "Application log file path:"
    read -r INPUT_FILE
    ;;
  *)
    echo "Invalid service selection." >&2
    return 1
    ;;
  esac
}

send_notification() {
  local findings=$1
  local host_name=${HOSTNAME:-}
  if [[ -z "$host_name" ]]; then
    host_name=$(hostname 2>/dev/null || printf 'unknown-host')
  fi
  if [[ -z "${LAZER_EMAIL_RECIPIENT:-}" ]]; then
    echo "Error: LAZER_EMAIL_RECIPIENT is not configured" >&2
    return 1
  fi
  if [[ -z "${LAZER_MAIL_COMMAND:-}" ]]; then
    echo "Error: LAZER_MAIL_COMMAND is not configured" >&2
    return 1
  fi
  printf '%s\n' "$findings" | "$LAZER_MAIL_COMMAND" \
    -s "Lazer anomaly detected on $host_name" "$LAZER_EMAIL_RECIPIENT"
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
  if [[ ! -f "$COMPLETION_DIR/lazer.bash" || ! -f "$COMPLETION_DIR/_lazer" ]]; then
    echo "Error: shell completion files are not available at '$COMPLETION_DIR'" >&2
    return 1
  fi
  sudo mkdir -p /usr/share/lazer/systemd /usr/share/lazer/completions \
    /etc/bash_completion.d /usr/share/zsh/site-functions
  sudo cp "$SCRIPT_DIR/lazer.sh" /usr/bin/lazer
  sudo cp "$PARSER_FILE" /usr/share/lazer/parsers.sh
  sudo cp "$COMPLETION_DIR/lazer.bash" /etc/bash_completion.d/lazer
  sudo cp "$COMPLETION_DIR/_lazer" /usr/share/zsh/site-functions/_lazer
  sudo cp "$COMPLETION_DIR/lazer.bash" "$COMPLETION_DIR/_lazer" /usr/share/lazer/completions/
  sudo cp "$SCRIPT_DIR/systemd/lazer.service" "$SCRIPT_DIR/systemd/lazer.timer" "$SCRIPT_DIR/systemd/lazer.env.example" /usr/share/lazer/systemd/
}

remove() {
  if [[ -f /etc/systemd/system/lazer.timer ]]; then
    sudo systemctl disable --now lazer.timer || true
  fi
  sudo rm -f /etc/systemd/system/lazer.timer /etc/systemd/system/lazer.service
  sudo systemctl daemon-reload
  sudo rm /usr/bin/lazer
  sudo rm -f /etc/bash_completion.d/lazer /usr/share/zsh/site-functions/_lazer
  sudo rm -f /usr/share/lazer/parsers.sh
  sudo rm -rf /usr/share/lazer
}

install_systemd_service() {
  local unit_source_dir="$SCRIPT_DIR/systemd"
  if [[ ! -d "$unit_source_dir" ]]; then
    unit_source_dir="/usr/share/lazer/systemd"
  fi
  if [[ ! -d "$unit_source_dir" ]]; then
    echo "Error: systemd templates are not available at '$unit_source_dir'" >&2
    return 1
  fi
  if [[ ! -f "$COMPLETION_DIR/lazer.bash" || ! -f "$COMPLETION_DIR/_lazer" ]]; then
    echo "Error: shell completion files are not available at '$COMPLETION_DIR'" >&2
    return 1
  fi
  sudo mkdir -p /etc/lazer
  sudo mkdir -p /usr/share/lazer/completions /etc/bash_completion.d /usr/share/zsh/site-functions
  sudo cp "$SCRIPT_DIR/lazer.sh" /usr/bin/lazer
  sudo cp "$PARSER_FILE" /usr/share/lazer/parsers.sh
  sudo cp "$COMPLETION_DIR/lazer.bash" /etc/bash_completion.d/lazer
  sudo cp "$COMPLETION_DIR/_lazer" /usr/share/zsh/site-functions/_lazer
  sudo cp "$COMPLETION_DIR/lazer.bash" "$COMPLETION_DIR/_lazer" /usr/share/lazer/completions/
  sudo cp "$unit_source_dir/lazer.service" /etc/systemd/system/lazer.service
  sudo cp "$unit_source_dir/lazer.timer" /etc/systemd/system/lazer.timer
  if [[ ! -f /etc/lazer/lazer.env ]]; then
    sudo cp "$unit_source_dir/lazer.env.example" /etc/lazer/lazer.env
    sudo chmod 600 /etc/lazer/lazer.env
    echo "Edit /etc/lazer/lazer.env before starting the timer."
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now lazer.timer
}

welcome() {
  echo "

██╗      █████╗ ███████╗███████╗██████╗ 
██║     ██╔══██╗╚══███╔╝██╔════╝██╔══██╗
██║     ███████║  ███╔╝ █████╗  ██████╔╝
██║     ██╔══██║ ███╔╝  ██╔══╝  ██╔══██╗
███████╗██║  ██║███████╗███████╗██║  ██║
╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝

	"
  echo $'\n'$"Enter a selection from the folowing list..."
  echo "1 - Install lazer to PATH"
  echo "2 - View local statistics (choose service)"
  echo "3 - Run AI anomaly analysis (choose service)"
  echo "4 - Install systemd service to notify on anomalies"
  echo "5 - Remove lazer from your system"
  if ! read -r selection; then
    error "a menu selection is required"
    return 1
  fi
  case $selection in
  1)
    setup
    ;;
  2)
    select_service && display
    ;;
  3)
    select_service && analyse
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
parse_cli_arguments "$@"

if ((NONINTERACTIVE)); then
  service_analysis
  exit $?
fi

if [[ -n "$CLI_ACTION" ]]; then
  case "$CLI_ACTION" in
  stats)
    display
    ;;
  analyze)
    analyse
    ;;
  esac
  exit $?
fi

if ((CLI_INPUT_SELECTION)); then
  if [[ "$SOURCE_TYPE" == systemd_journal ]]; then
    echo "Error: --source systemd_journal requires --stats or --analyze" >&2
    exit 1
  fi
  select_action || exit 1
  case "$CLI_ACTION" in
  stats)
    display
    ;;
  analyze)
    analyse
    ;;
  esac
  exit $?
fi

welcome
