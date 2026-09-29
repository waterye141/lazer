#!/bin/bash
set -e

log_file=$1

display() {
	if [[ -z "$log_file" ]]; then
		log_file=$(sudo nginx -T 2>/dev/null \
			| grep -oP '(?<=access_log\s)\S+' \
			| head -1)
	fi

	if [[ -z "$log_file" ]]; then
		log_file="/var/log/nginx/access.log"
	fi

	if [[ ! -f "$log_file" ]]; then
		echo $'\n'$"Log file not found, please provide the log file path: "
		read -r log_file;
	fi

	if [[ ! -f "$log_file" ]]; then
		echo "Error: access log not found at '$log_file'" >&2
		echo "Usage: $0 /path/to/access.log" >&2
		exit 1
	fi

	local FIRST_LINE
	FIRST_LINE=$(grep -m1 '[^[:space:]]' "$log_file" 2>/dev/null || true)
	if [[ -z "$FIRST_LINE" ]]; then
		echo "Error: file is empty" >&2
		exit 1
	fi

	if ! echo "$FIRST_LINE" | grep -qP '^\S+\s+\S+\s+\S+\s+\[.+?\]\s+"[A-Z]+\s+\S+\s+HTTP/\d\.\d"\s+\d{3}\s+\S+'; then
		echo "Error: '$log_file' does not look like an nginx access log" >&2
		echo "  First line: $FIRST_LINE" >&2
		exit 1
	fi

	echo "How many lines do you want to display?:"
	read -r count;

	clear

	echo -e "\nTop $count IP addresses with the most requests:"
	awk '{print $1}' "$log_file" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$count"

	echo -e "\nTop $count most requested paths:"
	awk '{print $7}' "$log_file" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n "$count"

	echo -e "\nTop $count response status codes:"
	grep -oE ' [0-9][0-9][0-9] ' "$log_file" | sort | uniq -c | sort -nr | head -n "$count" | awk '{printf "%s - %d Requests\n", $2, $1}'

	echo -e "\nTop $count user agents:"
	awk -F'"' '{print $6}' "$log_file" | sort | uniq -c | sort -nr | head -n "$count" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print "-",$1,"requests" }'
	printf "\n"
}

analyse() {
	# TODO: Add AI analysis
}

setup() {
	# TODO: Add install script
}

install_systemd_service() {
	# TODO: Add systemd service
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
	read -r selection;
	case $selection in
		1)
		setup
		;;
		2)
		display "$log_file"
		;;
		3)
		analyse "$log_file"
		;;
		4)
		install_systemd_service
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
