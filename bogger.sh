#!/bin/bash
set -e

NGINX_LOGFILE=nginx-access.log
# TODO: Add AI summary analysis for anomalies and issues

if [[ $# -ne 1 ]]; 
	then echo "Log file not provided"
	exit 1
fi

if [[ $1 != "$NGINX_LOGFILE" ]];
	then echo "Invalid log file"
	exit 2
fi

echo -e "\nTop 5 IP addresses with the most requests:"
awk '{print $1}' "$1" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n5

echo -e "\nTop 5 most requested paths:"
awk '{print $7}' "$1" | sort | uniq -c | sort -nr | awk '{printf "%s - %d Requests\n", $2, $1}' | head -n5

echo -e "\nTop 5 response status codes:"
grep -oE ' [0-9][0-9][0-9] ' "$1" | sort | uniq -c | sort -nr | head -n5 | awk '{printf "%s - %d Requests\n", $2, $1}'

echo -e "\nTop 5 user agents:"
awk -F'"' '{print $6}' "$1" | sort | uniq -c | sort -nr | head -n5 | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print "-",$1,"requests" }'
