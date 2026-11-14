#!/bin/bash

json_record() {
  local timestamp=$1
  local source=$2
  local severity=$3
  local message=$4
  local fields=$5
  [[ -n "$fields" ]] || fields='{}'
  jq -cn \
    --arg timestamp "$timestamp" \
    --arg source "$source" \
    --arg severity "$severity" \
    --arg message "$message" \
    --argjson fields "$fields" \
    '{timestamp: $timestamp, source: $source, severity: $severity, message: $message, fields: $fields}'
}

parse_http_line() {
  local source=$1
  local line=$2
  local ip timestamp method path protocol status bytes user_agent
  if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+\[([^]]+)\][[:space:]]+\"([A-Z]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(HTTP/[0-9.]+)\"[[:space:]]+([0-9]{3})[[:space:]]+([^[:space:]]+)([[:space:]]+\"[^\"]*\")?[[:space:]]+\"([^\"]*)\" ]]; then
    ip=${BASH_REMATCH[1]}
    timestamp=${BASH_REMATCH[2]}
    method=${BASH_REMATCH[3]}
    path=${BASH_REMATCH[4]}
    protocol=${BASH_REMATCH[5]}
    status=${BASH_REMATCH[6]}
    bytes=${BASH_REMATCH[7]}
    user_agent=${BASH_REMATCH[9]:-}
    json_record "$timestamp" "$source" "$([[ "$status" -ge 500 ]] && echo error || echo info)" "$line" \
      "$(jq -cn \
        --arg ip "$ip" \
        --arg method "$method" \
        --arg path "$path" \
        --arg protocol "$protocol" \
        --arg status "$status" \
        --arg bytes "$bytes" \
        --arg user_agent "$user_agent" \
        '{ip: $ip, method: $method, path: $path, protocol: $protocol, status: ($status | tonumber), bytes: $bytes, user_agent: $user_agent}')"
    return 0
  fi
  return 1
}

parse_syslog_line() {
  local source=$1
  local line=$2
  local timestamp host process message severity
  if [[ "$line" =~ ^([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8})[[:space:]]+([^[:space:]]+)[[:space:]]+([^:]+):[[:space:]]+(.*)$ ]]; then
    timestamp=${BASH_REMATCH[1]}
    host=${BASH_REMATCH[2]}
    process=${BASH_REMATCH[3]}
    message=${BASH_REMATCH[4]}
    severity=info
    [[ "$message" =~ (failed|failure|error|invalid|attack|denied) ]] && severity=warning
    json_record "$timestamp" "$source" "$severity" "$line" \
      "$(jq -cn --arg host "$host" --arg process "$process" --arg message "$message" '
        {ip: (if ($message | capture("(?<ip>[0-9]{1,3}(\\.[0-9]{1,3}){3})")?) then ($message | capture("(?<ip>[0-9]{1,3}(\\.[0-9]{1,3}){3})").ip) else "N/A" end),
         path: "N/A", status: null, user_agent: "N/A", host: $host, process: $process}')"
    return 0
  fi
  return 1
}

parse_docker_line() {
  local line=$1
  if jq -e 'type == "object" and (.log? != null)' >/dev/null 2>&1 <<<"$line"; then
    jq -c --arg source docker '
      {
        timestamp: (.time // ""),
        source: $source,
        severity: (if ((.log // "") | test("(?i)(error|fail|fatal|denied)")) then "warning" else "info" end),
        message: ((.log // "") | rtrimstr("\n")),
        fields: {ip: "N/A", path: "N/A", status: null, user_agent: "N/A", stream: (.stream // "")}
      }' <<<"$line"
    return 0
  fi
  return 1
}

parse_haproxy_line() {
  local line=$1
  local ip status request method path protocol timestamp
  if [[ "$line" =~ ^([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8})[[:space:]]+ ]]; then
    timestamp=${BASH_REMATCH[1]}
  else
    timestamp=""
  fi
  ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' <<<"$line" | head -n 1 | cut -d: -f1)
  status=$(grep -oE '[[:space:]][0-9]{3}[[:space:]]' <<<"$line" | tail -n 1 | tr -d ' ')
  request=$(grep -oE '"[A-Z]+ [^"]+ HTTP/[0-9.]+"' <<<"$line" | tail -n 1)
  if [[ -n "$ip" && -n "$status" && "$request" =~ \"([A-Z]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(HTTP/[0-9.]+)\" ]]; then
    method=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    protocol=${BASH_REMATCH[3]}
    json_record "$timestamp" haproxy "$([[ "$status" -ge 500 ]] && echo error || echo info)" "$line" \
      "$(jq -cn \
        --arg ip "$ip" \
        --arg method "$method" \
        --arg path "$path" \
        --arg protocol "$protocol" \
        --arg status "$status" \
        '{ip: $ip, method: $method, path: $path, protocol: $protocol, status: ($status | tonumber), bytes: "N/A", user_agent: "N/A"}')"
    return 0
  fi
  return 1
}

parse_generic_line() {
  local source=$1
  local line=$2
  local timestamp message severity
  if [[ "$line" =~ ^(([0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+)|([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8}))([[:space:]]+|$)(.*)$ ]]; then
    timestamp=${BASH_REMATCH[1]}
    message=${BASH_REMATCH[5]}
  else
    timestamp=""
    message=$line
  fi
  severity=info
  [[ "$message" =~ (failed|failure|error|invalid|attack|denied|fatal) ]] && severity=warning
  json_record "$timestamp" "$source" "$severity" "$line" \
    '{"ip":"N/A","path":"N/A","status":null,"user_agent":"N/A"}'
}

parse_line() {
  local source=$1
  local line=$2
  case "$source" in
  nginx|apache)
    parse_http_line "$source" "$line" || parse_generic_line "$source" "$line"
    ;;
  ssh|haproxy)
    if [[ "$source" == haproxy ]]; then
      parse_haproxy_line "$line" || parse_syslog_line "$source" "$line" || parse_generic_line "$source" "$line"
    else
      parse_syslog_line "$source" "$line" || parse_generic_line "$source" "$line"
    fi
    ;;
  docker)
    parse_docker_line "$line" || parse_generic_line "$source" "$line"
    ;;
  generic)
    parse_generic_line "$source" "$line"
    ;;
  *)
    echo "Error: unsupported parser source '$source'" >&2
    return 1
    ;;
  esac
}

parse_journal_line() {
  jq -c '
    {
      timestamp: (.__REALTIME_TIMESTAMP // ""),
      source: "systemd_journal",
      severity: (if ((.PRIORITY // "6") | tonumber) <= 3 then "error" elif ((.PRIORITY // "6") | tonumber) <= 4 then "warning" else "info" end),
      message: (.__MESSAGE // ""),
      fields: {
        ip: "N/A",
        path: "N/A",
        status: null,
        user_agent: "N/A",
        unit: (._SYSTEMD_UNIT // ""),
        facility: (.SYSLOG_FACILITY // ""),
        pid: (._PID // "")
      }
    }'
}

parse_input_to_records() {
  local source=$1
  local input_file=${2:-}
  local output_file=$3
  local line record parse_errors=0 record_count=0

  if [[ "$source" == systemd_journal ]]; then
    if ! command -v journalctl >/dev/null 2>&1; then
      echo "Error: journalctl is required for systemd_journal input" >&2
      return 1
    fi
    if ! journalctl --no-pager -o json ${JOURNALCTL_ARGS:-} >"$output_file"; then
      echo "Error: journalctl could not read the requested input" >&2
      return 1
    fi
    local journal_tmp
    journal_tmp=$(mktemp)
    while IFS= read -r line; do
      if record=$(printf '%s\n' "$line" | parse_journal_line); then
        printf '%s\n' "$record" >>"$journal_tmp"
        ((record_count += 1))
      fi
    done <"$output_file"
    mv "$journal_tmp" "$output_file"
  else
    if [[ ! -f "$input_file" ]]; then
      echo "Error: log file not found at '$input_file'" >&2
      return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      if record=$(parse_line "$source" "$line"); then
        printf '%s\n' "$record" >>"$output_file"
        ((record_count += 1))
      else
        ((parse_errors += 1))
      fi
    done <"$input_file"
  fi

  if ((record_count == 0)); then
    echo "Error: no parseable records found for source '$source'" >&2
    return 1
  fi
  if ((parse_errors > 0)); then
    echo "Warning: skipped $parse_errors unrecognized log lines" >&2
  fi
}
