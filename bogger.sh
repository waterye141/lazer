#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; 
	then echo "Log file not provided"
	exit 1
fi

echo "Top 5 IP addresses with the most requests:"
awk '{print $1}' $1 | sort | uniq -c | sort -gr | head -n5 | awk '{printf "%s - %d Requests\n", $2, $1}'
