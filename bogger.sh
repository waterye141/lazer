#!/bin/bash
set -e

LOG_FILE=$1
OPENROUTER_API_KEY=$(cat .env)

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

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

display() {
  resolve_log_file
  echo "How many lines do you want to display?:"
  read -r COUNT
  clear
  stats_summary "$LOG_FILE" "$COUNT"

}

extract_content() {
  grep -o '"content":"\(\\.\|[^"\\]\)*"' | head -n 1
}

analyse() {
  resolve_log_file
  clear
  sleep 1
  local response
  response=$(
    curl -sS https://openrouter.ai/api/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENROUTER_API_KEY" \
      -d '{
		  "model": "nvidia/nemotron-3.5-lightning",
		  "messages": [
			{
			  "role" : "system",
			  "content" : "You are required to analyze the log files for anomalies and reply by your findings. Reply in one coherent paragraph"
			},
			{
			  "role": "user",
			  "content" : "'"$(printf 'Nginx summary for %s:\n%s\n\nLast 30 raw lines:\n%s\n\nTask: list anomalies.' "$LOG_FILE" "$(stats_summary "$LOG_FILE" 10 | json_escape)" "$(tail -n 30 "$LOG_FILE" | json_escape)")"'"
			}
		  ],
		  "temperature" : 0.2,
		  "max_tokens" : 6000
		}'
  )
  local final_response
  final_response=$(echo "$response" | extract_content | sed 's/^"content":"//; s/"$//')
  if [[ -z $final_response ]]; then echo "Error, sending request."; fi
  echo "$final_response"

}

setup() {
  sudo cp bogger.sh /usr/bin/bogger
}

remove() {
  sudo rm /usr/bin/bogger
}

install_systemd_service() {
  # TODO: Add systemd service
  true
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
  echo "4 - Install systmd service to notify on anomalies"
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

welcome
