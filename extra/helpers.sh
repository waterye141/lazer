resolve_log_file() {
		if [[ -z "$LOG_FILE" ]]; then
		LOG_FILE=$(sudo nginx -T 2>/dev/null \
			| grep -oP '(?<=access_log\s)\S+' \
			| head -1)
	fi

	if [[ -z "$LOG_FILE" ]]; then
		LOG_FILE="/var/log/nginx/access.log"
	fi

	if [[ ! -f "$LOG_FILE" ]]; then
		echo $'\n'$"Log file not found, please provide the log file path: "
		read -r LOG_FILE;
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
	echo -e "\nTop $count IP addresses with the most requests:"
	awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$count"

	echo -e "\nTop $count most requested paths:"
	awk '{print $7}' "$LOG_FILE" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$count"

	echo -e "\nTop $count response status codes:"
	grep -oE ' [0-9][0-9][0-9] ' "$LOG_FILE" | sort | uniq -c | sort -nr | head -n "$count" | awk '{printf "%s - %d Requests\n", $2, $1}'

	echo -e "\nTop $count user agents:"
	awk -F'"' '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -nr | head -n "$count" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print "-",$1,"requests" }'
	printf "\n"

}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' ... ; }

