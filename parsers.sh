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
  local ip timestamp method path protocol status bytes referrer user_agent
  local fields http_pattern status_class severity
  http_pattern='^([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+\[([^]]+)\][[:space:]]+"([A-Z]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(HTTP/[0-9.]+)"[[:space:]]+([0-9]{3})[[:space:]]+([^[:space:]]+)([[:space:]]+"[^"]*")?[[:space:]]+"([^"]*)"'
  if [[ "$line" =~ $http_pattern ]]; then
    ip=${BASH_REMATCH[1]}
    timestamp=${BASH_REMATCH[2]}
    method=${BASH_REMATCH[3]}
    path=${BASH_REMATCH[4]}
    protocol=${BASH_REMATCH[5]}
    status=${BASH_REMATCH[6]}
    bytes=${BASH_REMATCH[7]}
    referrer=${BASH_REMATCH[8]:-}
    referrer=${referrer# }
    referrer=${referrer#\"}
    referrer=${referrer%\"}
    user_agent=${BASH_REMATCH[9]:-}
    if ((status >= 500)); then
      status_class=5xx
      severity=error
    elif ((status >= 400)); then
      status_class=4xx
      severity=warning
    elif ((status >= 300)); then
      status_class=3xx
      severity=info
    elif ((status >= 200)); then
      status_class=2xx
      severity=info
    else
      status_class=other
      severity=warning
    fi
    fields=$(jq -cn \
      --arg ip "$ip" \
      --arg method "$method" \
      --arg path "$path" \
      --arg protocol "$protocol" \
      --arg status "$status" \
      --arg bytes "$bytes" \
      --arg referrer "$referrer" \
      --arg user_agent "$user_agent" \
      --arg status_class "$status_class" \
      '{ip: $ip, method: $method, path: $path, protocol: $protocol, status: ($status | tonumber), status_class: $status_class, bytes: $bytes, referrer: $referrer, user_agent: $user_agent}')
    json_record "$timestamp" "$source" "$severity" "$line" "$fields"
    return 0
  fi
  return 1
}

parse_syslog_line() {
  local source=$1
  local line=$2
  local timestamp host process message severity
  local fields jq_filter
  if [[ "$line" =~ ^([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8})[[:space:]]+([^[:space:]]+)[[:space:]]+([^:]+):[[:space:]]+(.*)$ ]]; then
    timestamp=${BASH_REMATCH[1]}
    host=${BASH_REMATCH[2]}
    process=${BASH_REMATCH[3]}
    message=${BASH_REMATCH[4]}
    severity=info
    [[ "$message" =~ (failed|failure|error|invalid|attack|denied|oom|killed) ]] && severity=warning
    jq_filter=$(cat <<'JQ_FILTER'
{ip: (if ($message | capture("(?<ip>[0-9]{1,3}(\\.[0-9]{1,3}){3})")?) then ($message | capture("(?<ip>[0-9]{1,3}(\\.[0-9]{1,3}){3})").ip) else "N/A" end),
 path: "N/A", status: null, user_agent: "N/A", host: $host, process: $process,
 event: (if ($message | test("(?i)failed|failure|invalid")) then "authentication_failure"
         elif ($message | test("(?i)accepted|success")) then "authentication_success"
         elif ($message | test("(?i)sudo|COMMAND=")) then "privilege_use"
         else "other" end),
 username: (if ($message | capture("for (invalid user )?(?<user>[A-Za-z0-9._-]+)")?) then ($message | capture("for (invalid user )?(?<user>[A-Za-z0-9._-]+)").user) else "N/A" end),
 source_port: (if ($message | capture("port (?<port>[0-9]+)")?) then ($message | capture("port (?<port>[0-9]+)").port | tonumber) else null end)}
JQ_FILTER
)
    fields=$(jq -cn --arg host "$host" --arg process "$process" --arg message "$message" "$jq_filter")
    json_record "$timestamp" "$source" "$severity" "$line" "$fields"
    return 0
  fi
  return 1
}

parse_docker_line() {
  local line=$1
  local jq_filter
  jq_filter='type == "object" and (.log? != null)'
  if jq -e "$jq_filter" >/dev/null 2>&1 <<<"$line"; then
    jq_filter=$(cat <<'JQ_FILTER'
{
  timestamp: (.time // ""),
  source: $source,
  severity: (if ((.log // "") | test("(?i)(oom|out of memory|fatal|panic|segfault)")) then "error" elif ((.log // "") | test("(?i)(error|fail|denied|timeout|unhealthy)")) then "warning" else "info" end),
  message: ((.log // "") | rtrimstr("\n")),
  fields: {
    ip: "N/A", path: "N/A", status: null, user_agent: "N/A",
    stream: (.stream // ""),
    method: (if ((.log // "") | test("^[A-Z]+ ")) then ((.log | capture("^(?<method>[A-Z]+) (?<path>[^ ]+) HTTP/[0-9.]+ (?<status>[0-9]{3})").method)) else "N/A" end),
    path: (if ((.log // "") | test("^[A-Z]+ ")) then ((.log | capture("^(?<method>[A-Z]+) (?<path>[^ ]+) HTTP/[0-9.]+ (?<status>[0-9]{3})").path)) else "N/A" end),
    status: (if ((.log // "") | test("^[A-Z]+ ")) then ((.log | capture("^(?<method>[A-Z]+) (?<path>[^ ]+) HTTP/[0-9.]+ (?<status>[0-9]{3})").status | tonumber)) else null end),
    event: (if ((.log // "") | test("(?i)oom|out of memory")) then "oom"
            elif ((.log // "") | test("(?i)health(check)?|unhealthy")) then "health"
            elif ((.log // "") | test("(?i)restart|starting|stopping|exited")) then "lifecycle"
            elif ((.log // "") | test("(?i)timeout|connection refused|upstream")) then "dependency"
            else "application" end),
    status_class: (if ((.log // "") | test("HTTP/[0-9.]+ 5[0-9]{2}")) then "5xx"
                   elif ((.log // "") | test("HTTP/[0-9.]+ 4[0-9]{2}")) then "4xx"
                   elif ((.log // "") | test("HTTP/[0-9.]+ 2[0-9]{2}")) then "2xx"
                   else "N/A" end)
  }
}
JQ_FILTER
)
    jq -c --arg source docker "$jq_filter" <<<"$line"
    return 0
  fi
  return 1
}

parse_haproxy_line() {
  local line=$1
  local ip status request method path protocol timestamp
  local fields request_pattern haproxy_pattern frontend backend_server timing termination severity
  request_pattern='"([A-Z]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(HTTP/[0-9.]+)"'
  if [[ "$line" =~ ^([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9:]{8})[[:space:]]+ ]]; then
    timestamp=${BASH_REMATCH[1]}
  else
    timestamp=""
  fi
  ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' <<<"$line" | head -n 1 | cut -d: -f1)
  status=$(grep -oE '[[:space:]][0-9]{3}[[:space:]]' <<<"$line" | tail -n 1 | tr -d ' ')
  request=$(grep -oE '"[A-Z]+ [^"]+ HTTP/[0-9.]+"' <<<"$line" | tail -n 1)
  haproxy_pattern='\\] ([^[:space:]]+) ([^[:space:]]+) ([0-9]+/[0-9]+/[0-9]+/[0-9]+/[0-9]+) ([0-9]{3}) ([0-9]+) ([^[:space:]]+)'
  if [[ "$line" =~ $haproxy_pattern ]]; then
    frontend=${BASH_REMATCH[1]}
    backend_server=${BASH_REMATCH[2]}
    timing=${BASH_REMATCH[3]}
    termination=${BASH_REMATCH[6]}
    backend=${backend_server%%/*}
  else
    frontend=N/A
    backend_server=N/A
    backend=N/A
    timing=N/A
    termination=N/A
  fi
  if [[ -n "$ip" && -n "$status" && "$request" =~ $request_pattern ]]; then
    method=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    protocol=${BASH_REMATCH[3]}
    fields=$(jq -cn \
      --arg ip "$ip" \
      --arg method "$method" \
      --arg path "$path" \
      --arg protocol "$protocol" \
      --arg status "$status" \
      --arg frontend "$frontend" \
      --arg backend "$backend" \
      --arg backend_server "$backend_server" \
      --arg timing "$timing" \
      --arg termination "$termination" \
      '{ip: $ip, method: $method, path: $path, protocol: $protocol, status: ($status | tonumber), bytes: "N/A", user_agent: "N/A", frontend: $frontend, backend: $backend, backend_server: $backend_server, timing: $timing, termination_state: $termination}')
      if ((status >= 500)); then
        severity=error
      elif ((status >= 400)); then
        severity=warning
      else
        severity=info
      fi
      json_record "$timestamp" haproxy "$severity" "$line" "$fields"
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
  nginx | apache)
    parse_http_line "$source" "$line" || parse_generic_line "$source" "$line"
    ;;
  ssh | haproxy)
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
  local jq_filter
  jq_filter=$(cat <<'JQ_FILTER'
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
    ,event: (if ((.__MESSAGE // "") | test("(?i)oom|out of memory")) then "oom"
             elif ((.__MESSAGE // "") | test("(?i)failed|failure|crash|segfault")) then "failure"
             elif ((.__MESSAGE // "") | test("(?i)started|starting|stopped|stopping|restart")) then "lifecycle"
             else "other" end)
  }
}
JQ_FILTER
)
  jq -c "$jq_filter"
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
    if [[ ! "${JOURNALCTL_LINES:-1000}" =~ ^[1-9][0-9]*$ ]]; then
      echo "Error: LAZER_JOURNAL_LINES must be a positive integer" >&2
      return 1
    fi
    local -a journal_args=()
    if [[ -n "${JOURNALCTL_ARGV+x}" ]]; then
      journal_args=("${JOURNALCTL_ARGV[@]}")
    fi
    if ((${#journal_args[@]} == 0)) && [[ -n "${JOURNALCTL_ARGS:-}" ]]; then
      read -r -a journal_args <<<"$JOURNALCTL_ARGS"
    fi
    if ! journalctl --no-pager -o json -n "${JOURNALCTL_LINES:-1000}" "${journal_args[@]}" >"$output_file"; then
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
