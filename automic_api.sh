#!/usr/bin/env bash
################################################################################
# Script Name:    automic-api.sh
# Description:    Automic REST abstraction layer to handle some of the automic REST-API functions. Designed to be 
#                 used like a command from a parent script. It provides one wrapper function per Automic REST-API function
#                 and provides proper error and output-handling as well as a clear output strategy and logging.
#
# Author:         René Kappel
# Created:        2026-01-22
# License:        Permissive license model (MIT).
#                 Allows free use, copying, modification, merging, publishing, distribution, sublicensing, and private/commercial use.
#                 Full license description: https://opensource.org/licenses/MIT
#
# Version:        see below
#
# Change History:
#   v1.0.0 - 2026-01-22 - René Kappel
#       * Initial release - supported funtions: 
#             * ping
#             * system/health
#             * POST /{client}/executions (execute object)
#             * GET  /{client}/executions (query process monitoring)
#
# Notes:
#   - Review carefully before usage and modification.
#   - Tested on Linux Bash.
#
#
# Design rule:
#   Any function used in command substitution $(...) MUST exit the script on error
#   and must not return non-zero to its caller.
#
#
# Error-Codes:
#   10  Invalid arguments
#   20  Environment / config / dependency failure
#   22  REST transport or HTTP error
#   30  API semantic error (missing fields)
#   40  Timeout
#   50  Malformed API response
#   60  Unsupported function
#   62  function inventory mismatch
#   64  missing function inputs
#   70  AE execution failure
#
#
#  Output channel purpose
#  stdout :  machine-readable output
#  stderr :  user-visible errors
#  logfile:  diagnostics / debugging
#  
# ToDos:
# 
#   AE_QUERY_STRING
#   AE_FILTER_STRING
#   API_REQUIRED
#   API_OPTIONAL
#   JQ_VERSION
#   LOG_KEEP_DAYS   # read but never enforced#   
#   
#   
#   
#   
#   
#
#  
################################################################################

SCRIPT_VERSION="0.9.5"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "ERROR: Bash >= 4.3 required (found ${BASH_VERSION})" >&2
  exit 20
fi

set -euo pipefail

#######################################
# Defaults
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/automic-api.conf"

DEBUG=false

AE_API_FUNCTION=""
AE_ENV=""
AE_CLIENT=""
AE_OBJECT_NAME=""
AE_PARAMETER_STRING=""
AE_QUERY_STRING=""
AE_FILTER_STRING=""
AE_EXEC_TIMEOUT=10
AE_EXEC_NOWAIT=false
AE_IGNORE_FINAL_STATUS=false

API_BASE_URL=""
API_AUTH_MODE=""
API_TOKEN=""
API_BASIC_B64=""
API_USERNAME=""
API_PASSWORD=""

API_CONNECT_TIMEOUT=2
API_MAXTIME=600
API_RETRY_COUNT=2
API_RETRY_DELAY=120
API_OUTPUT="json"

API_SILENT=false

LOG_FILE="${SCRIPT_DIR}/automic-api.log"
LOG_KEEP_DAYS=7

FUNCTIONS_JSON=""
FUNCTIONS_FILE="${SCRIPT_DIR}/automic-api.functions.json"

declare -A API_REQUIRED API_OPTIONAL


#######################################
# Main routine
#######################################
main() {
  #echo "rotating logs"
  detect_platform
  init_logging

  log "main" "===== New run starts here ====="
  #echo "checking dependencies"
  check_tools

  load_functions
  validate_function_inventory
  
  #echo "parsing arguments"
  parse_arguments "$@"

  #echo "validating arguments"
  validate_arguments

  #echo "loading config"
  load_config_file

  #echo "building final url"
  build_final_config # overwrite values from config_file with those provided as cli parameters

  validate_function_inputs

  #echo "executing request"
  execute_request

}

validate_function_inventory() {
  local missing_in_code=()
  local missing_in_json=()
  local fn

  #######################################
  # 1. JSON → Code
  #######################################
  while read -r fn; do
    if ! function_exists "ae_${fn}"; then
      missing_in_code+=("$fn")
    fi
  done < <(
    jq -r '
      to_entries[]
      | select(.key != "_cli_map")
      | .key
    ' <<<"$FUNCTIONS_JSON"
  )

  #######################################
  # 2. Code → JSON
  #######################################
  while read -r fn; do
    fn="${fn#ae_}"
    if ! function_defined "$fn"; then
      missing_in_json+=("$fn")
    fi
  done < <(
    compgen -A function ae_
  )

  #######################################
  # 3. Report
  #######################################
  if (( ${#missing_in_code[@]} > 0 || ${#missing_in_json[@]} > 0 )); then
    echo "ERROR: Function inventory mismatch detected" >&2
    echo >&2

    if (( ${#missing_in_code[@]} > 0 )); then
      echo "Functions declared in JSON but missing in code:" >&2
      for fn in "${missing_in_code[@]}"; do
        echo "  - $fn" >&2
      done
      echo >&2
    fi

    if (( ${#missing_in_json[@]} > 0 )); then
      echo "Functions implemented in code but missing in JSON:" >&2
      for fn in "${missing_in_json[@]}"; do
        echo "  - $fn" >&2
      done
      echo >&2
    fi

    exit 62
  fi

  log "inventory" "Function inventory validation successful"
}

execute_request() {
  local fn="ae_${AE_API_FUNCTION}"

  if ! function_exists "$fn"; then
    echo "ERROR: Unsupported API function '$AE_API_FUNCTION'" >&2
    echo
    print_functions_overview
    exit 60
  fi

  log "dispatcher" "Executing function: $fn"
  "$fn"
}


#######################################
# Usage
#######################################
usage() {
  local fd="${1:-1}"   # default: stdout
  cat >&"$fd" <<EOF
Usage:
  $0 -f <ae_api_function> -e <ae_environment> -c <client> -o <object_name> [options]

Required:
  -f <ae_api_function>    API function to execute (for a list of supported functions use '--help')
  -e <ae_environment>     ae environment as per config file
  
Depending on function
  -c <client>             Automic client
  -o <object_name>        object name (Job, Agent, etc)

Options:
  -p <parameters>         KEY=VALUE[,KEY=VALUE]
  --output                define format of output : json|raw (default: json)
  -t <seconds>            max wait time for execution to finish (default: 10)
  -d, --debug             enable debug mode with verbose output
  -h, --help              show this message
  --show-config           prints the config from config file to screen
  --nowait                don't wait for task execution to finish (only used with '-f execute_task')
  --ignore-jobstatus      ignore final job status 
  
EOF
}

fail_usage() {
  usage 2
  [[ "${BASH_SOURCE[0]}" != "$0" ]] && return 20 || exit 20
}

print_functions_overview() {

  local width

  # Determine max function name width
  width="$(jq -r '
    to_entries[]
    | select(.key != "_cli_map")
    | .key
  ' <<<"$FUNCTIONS_JSON" \
  | awk '{ if (length > max) max = length } END { print max }')"

  # Header
  printf '%s\n\n' "Currently supported functions are:"
  printf "%-${width}s  %s\n" "Function" "Description"
  printf "%-${width}s  %s\n" \
    "$(printf '%*s' "$width" '' | tr ' ' '-')" \
    "-----------"

  # Rows
  jq -r '
    to_entries[]
    | select(.key != "_cli_map")
    | [.key, .value.help]
    | @tsv
  ' <<<"$FUNCTIONS_JSON" |
  while IFS=$'\t' read -r fn desc; do
    printf "%-${width}s  %s\n" "$fn" "$desc"
  done
}

print_function_help() {
  local fn="$1"

  function_defined "$fn" || {
    echo "ERROR: Unknown function '$fn'" >&2
    exit 61
  }

  echo "Function: $fn"
  echo "Description:"
  echo "  $(function_help_line "$fn")"
  echo

  echo "Required arguments:"
  if function_vars "$fn" required | grep -q .; then
    while read -r var; do
      echo "  $(cli_flag_for_var "$var")"
    done < <(function_vars "$fn" required)
  else
    echo "  (none)"
  fi

  echo
  echo "Optional arguments:"
  if function_vars "$fn" optional | grep -q .; then
    while read -r var; do
      echo "  $(cli_flag_for_var "$var")"
    done < <(function_vars "$fn" optional)
  else
    echo "  (none)"
  fi
}


#######################################
# Logging
#######################################
detect_platform() {
  if date +%s%N >/dev/null 2>&1; then
    HAVE_GNU_DATE=true
  else
    HAVE_GNU_DATE=false
  fi
}

timestamp() {
  if $HAVE_GNU_DATE; then
    date +"%Y%m%d/%H%M%S.%3N"
  else
    date +"%Y%m%d/%H%M%S"
  fi
}

mask_secrets() {
  sed -E 's/(Authorization: ).*/\1<MASKED>/'
}


init_logging() {
  local dir today last_change_date

  dir="$(dirname "$LOG_FILE")"
  today="$(date +%Y%m%d)"

  # 1. Ensure log directory exists and is writable
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || {
      echo "ERROR: Cannot create log directory: $dir" >&2
      exit 20
    }
  fi

  [[ -w "$dir" ]] || {
    echo "ERROR: Log directory not writable: $dir" >&2
    exit 20
  }

  # 2. Rotate existing log if it exists and is not from today
  if [[ -f "$LOG_FILE" ]]; then
    last_change_date="$(date -r "$LOG_FILE" +%Y%m%d)"
    if [[ "$last_change_date" != "$today" ]]; then
      mv "$LOG_FILE" "$LOG_FILE.$last_change_date" 2>/dev/null || {
        echo "ERROR: Failed to rotate log file" >&2
        exit 20
      }
    fi
  fi

  : >>"$LOG_FILE" 2>/dev/null || {
    echo "ERROR: Cannot write log file: $LOG_FILE" >&2
    exit 20
  }

  if [[ ! -s $LOG_FILE ]]; then
    printf '%s - [INFO] - [main] - Version=%s Bash=%s OS=%s\n' \
    "$(timestamp)" "$SCRIPT_VERSION" "$BASH_VERSION" "$(uname -srm)" \
    >>"$LOG_FILE"
  fi

}

log() {
  local func="$1"
  local msg="$2"
  local level="${3:-INFO}"

  if [[ "$msg" == *$'\n'* ]]; then
      # Multiline message
      while IFS= read -r line || [[ -n "$line" ]]; do
          printf '%s - [%s] - [%s] - %s\n' \
              "$(timestamp)" "$level" "$func" "$line" >>"$LOG_FILE"
      done <<< "$msg"
  else
      # Single-line message
      printf '%s - [%s] - [%s] - %s\n' \
          "$(timestamp)" "$level" "$func" "$msg" >>"$LOG_FILE"
  fi
}

log_error() {
  log "$1" "$2" "ERROR"
}

debug() {
  if $DEBUG; then 
    log "$1" "$2" "DEBUG"
  fi
}


#######################################
# External tool checks
#######################################
check_tools() {
  local missing=()
  for t in jq curl mktemp tr base64 sleep date find; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done

  if command -v jq >/dev/null; then
    JQ_VERSION="$(jq --version 2>/dev/null)"
  fi

  [[ "${#missing[@]}" -eq 0 ]] || {
    log_error "tools" "Missing tools: ${missing[*]}"
    echo "ERROR: Missing tools: ${missing[*]}"
    exit 20
  }
}


#######################################
# Argument handling
#######################################
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f)                   AE_API_FUNCTION="$2"; shift 2 ;;
      -e)                   AE_ENV="$2"; shift 2 ;;
      -c)                   AE_CLIENT="$2"; shift 2 ;;
      -o)                   AE_OBJECT_NAME="$2"; shift 2 ;;
      -p)                   AE_PARAMETER_STRING="$2"; shift 2 ;;
      -t)                   AE_EXEC_TIMEOUT="$2"; shift 2 ;;
      --filter)             AE_FILTER_STRING="$2"; shift 2 ;;
      -d|--debug)           DEBUG=true; shift ;;
      -h|--help)            if [[ -n "${2:-}" && "$2" != -* ]]; then
                              print_function_help "$2"
                            else
                              print_functions_overview
                            fi
                            exit 0
                            ;;
      --show-config)        show_config; exit 0; shift ;;
      --nowait)             AE_EXEC_NOWAIT=true; shift ;;
      --output)             API_OUTPUT="$2"; shift 2 ;;
      --ignore-jobstatus)   AE_IGNORE_FINAL_STATUS=true; shift 1;;
      *)                    echo "Unknown option $1" >&2; fail_usage ;;
    esac
  done
}

validate_arguments() {
  
  [[ -n "$AE_API_FUNCTION" ]] || fail_usage
  #[[ -n "$AE_CLIENT" ]] || fail_usage
  #[[ -n "$AE_OBJECT_NAME" ]] || fail_usage
  #[[ -n "$API_METHOD" ]] || fail_usage
  #[[ -n "$API_ENDPOINT" ]] || fail_usage
  [[ -n "$AE_ENV" ]] || fail_usage
  [[ "$AE_EXEC_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "ERROR: -t must be numeric"; exit 10; }
}


#######################################
# Config loader (INI, pure Bash)
#######################################
load_config_file() {
  local section="" line key value var
  [[ -f "$CONFIG_FILE" ]] || { 
    echo "ERROR: Config not found";
    log_error "config" "Config not found"; 
    exit 20; 
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%[#;]*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]//[[:space:]]/}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      var="CFG_${section}_${key}"
      var="${var//[^a-zA-Z0-9_]/_}"
      printf -v "$var" '%s' "$value"
      debug "config" "${var} = ${!var}"
    fi
  done < "$CONFIG_FILE"
}

build_final_config() {
  # Common config
  API_MAXTIME="${CFG_common_timeout:-}"
  API_CONNECT_TIMEOUT="${CFG_common_connect_timeout:-}"
  API_RETRY_COUNT="${CFG_common_retry:-$API_RETRY_COUNT}"
  API_RETRY_DELAY="${CFG_common_retry_delay:-0}"
  LOG_FILE="${CFG_common_log_file:-$LOG_FILE}"
  LOG_KEEP_DAYS="${CFG_common_log_keep_days:-$LOG_KEEP_DAYS}"

  # Service config
  var="CFG_${AE_ENV}_url"; API_BASE_URL="${!var:-}"
  var="CFG_${AE_ENV}_auth_method"; API_AUTH_MODE="${!var:-}"
  var="CFG_${AE_ENV}_auth_token"; API_TOKEN="${!var:-}"
  var="CFG_${AE_ENV}_auth_b64"; API_BASIC_B64="${!var:-}"
  var="CFG_${AE_ENV}_user"; API_USERNAME="${!var:-}"
  var="CFG_${AE_ENV}_pass"; API_PASSWORD="${!var:-}"

  [[ -n "$API_BASE_URL" ]] || { log "ERROR" "config" "Base URL missing"; exit 20; }

  debug "config" "AE_CLIENT: ${AE_CLIENT}"
  debug "config" "AE_OBJECT_NAME: ${AE_OBJECT_NAME}"
}


#######################################
# Config dump
#######################################
show_config() {
  local var key

  echo "=== Configuration dump ==="
  echo "Config file   : $CONFIG_FILE"
  echo "Config section: $AE_ENV"
  echo

  echo "[common]"
  for var in $(compgen -A variable CFG_common_); do
    key="${var#CFG_common_}"
    printf '%s=%q\n' "$key" "${!var}"
  done | sort
  echo

  echo "[$AE_ENV]"
  for var in $(compgen -A variable "CFG_${AE_ENV}_"); do
    key="${var#CFG_${AE_ENV}_}"
    printf '%s=%q\n' "$key" "${!var}"
  done | sort
}


#######################################
# REST API Wrapper 
#######################################
rest_api() {
  declare -n _req="$1"
  local tmp_body tmp_headers url attempt http_status
  declare -a req_headers

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
  trap 'rm -f "${tmp_body:-}" "${tmp_headers:-}"' EXIT

  build_request_headers req_headers

  REST_CMD=(curl -sS --compressed \
    -X "${_req[method]}" \
    -o "$tmp_body" \
    -D "$tmp_headers" \
    -w '%{http_code}' \
    --max-time "$API_MAXTIME" \
    --connect-timeout "$API_CONNECT_TIMEOUT" \
    )

  # add headers
  for h in "${req_headers[@]}"; do
    REST_CMD+=(-H "$h")
  done

  if [[ -n "${_req[payload]:-}" ]]; then
    REST_CMD+=(--data "${_req[payload]}")
  fi
  
  url="${API_BASE_URL%/}/${_req[endpoint]#/}"
  if [[ -n "${_req[query]:-}" ]]; then
    url+="?${_req[query]}"
  fi
  REST_CMD+=("$url")

  debug "command" "${REST_CMD[*]}"

  attempt=0
  while true; do
    attempt=$((attempt + 1))
    log "curl" "Attempt $attempt: ${_req[method]} $url"
    
    if ! http_status="$("${REST_CMD[@]}" 2>>"$LOG_FILE")"; then
      rc=$?
    else
      rc=0
    fi
    log "curl" "Return code: $rc - HTTP-Status: $http_status"
    
    [[ $rc -eq 0 && "$http_status" -lt 500 ]] && break
    [[ "$attempt" -lt "$API_RETRY_COUNT" ]] || break
    sleep "$API_RETRY_DELAY"
  done

  #######################################
  # Result
  #######################################
  if [[ $rc -ne 0 || "$http_status" -ge 400 ]]; then
    log_error "curl" "Failure (HTTP-Status: $http_status)"
    debug "response" "headers:"
    debug "response" "$(sed '$a\' "$tmp_headers")"
    log_error "curl" "$(cat "$tmp_body")"
    {
      echo "ERROR: HTTP failure ($http_status)"
      sed -e '$a\' "$tmp_body"
    } >&2
    exit 22
  fi

  debug "response" "headers:"
  debug "response" "$(sed '$a\' "$tmp_headers")"
  debug "response" "body:"
  debug "response" "$(sed '$a\' "$tmp_body")"

  if ! $API_SILENT; then
    if [[ "$API_OUTPUT" == "raw" ]]; then
      cat "$tmp_body"
    else
      if jq -e . "$tmp_body" >/dev/null 2>&1; then
        jq -n \
          --arg status "$http_status" \
          --rawfile headers "$tmp_headers" \
          --slurpfile body "$tmp_body" \
          '{
            status: ($status | tonumber),
            headers: $headers,
            body: $body[0]
          }'
      else
        jq -n \
          --arg status "$http_status" \
          --arg headers "$(cat "$tmp_headers")" \
          --slurpfile body "$tmp_body" \
          '{
            status: ($status | tonumber),
            headers: $headers,
            body: {
              type: "json",
              value: $body
            }
          }'
      fi
    fi
  fi
}

with_silence() {
  local old="$API_SILENT"
  API_SILENT=true
  "$@"
  API_SILENT="$old"
}


#######################################
# Build request headers
#######################################
build_request_headers() {

  declare -n _req_headers=$1
  local h
  _req_headers=(
    "Content-Type: application/json"
    "Accept: application/json"
    "Accept-Encoding: identity"
  )

  case "$API_AUTH_MODE" in
    token)
      _req_headers+=("Authorization: Bearer $API_TOKEN")
      ;;
    basic_b64)
      _req_headers+=("Authorization: Basic $API_BASIC_B64")
      ;;
    basic_userpass)
      _req_headers+=("Authorization: Basic $(printf '%s:%s' "$API_USERNAME" "$API_PASSWORD" | base64 | tr -d '\n')")
      ;;
  esac

  debug "request" "headers: ${#_req_headers[@]}"
  debug "request" "$(printf '%s\n' "${_req_headers[@]}" | mask_secrets)"
}


#######################################
# Build request URL
# URL = BASE_URL + ENDPOINT + QUERY + FILTER
#######################################
#build_url() {
#  local endpoint="$1"
#  local query="${2:-}"
#  _url="${API_BASE_URL%/}/${endpoint#/}${query:+?$query}"
#}


#######################################
# Build payload 
#######################################
build_payload() {

  local inputs_json="{}"
  local payload
  
  if [[ -n "$AE_PARAMETER_STRING" ]]; then
    inputs_json="$(jq -n '
      ($ARGS.positional[0] | split(",")) as $p
      | reduce $p[] as $i ({}; 
          ($i|split("=")) as [$k,$v]
          | . + {($k):$v})
    ' --args "$AE_PARAMETER_STRING")"
  fi

  payload="$(jq -c -n \
    --arg obj "$AE_OBJECT_NAME" \
    --argjson inp "$inputs_json" \
    '{object_name:$obj} + (if ($inp|length)>0 then {inputs:$inp} else {} end)'
  )"

  debug "request" "payload:"
  debug "request" "$(jq . <<<"$payload")"

  jq -c . <<<"$payload"
}


#######################################
# build function inventory
#######################################
load_functions() {
  [[ -f "$FUNCTIONS_FILE" ]] || {
    echo "ERROR: Functions definition file not found: $FUNCTIONS_FILE" >&2
    exit 20
  }

  FUNCTIONS_JSON="$(jq -c '.' "$FUNCTIONS_FILE")" || {
    echo "ERROR: Failed to parse functions JSON" >&2
    exit 21
  }
}

function_defined() {
  jq -e --arg fn "$1" '.[$fn] != null' <<<"$FUNCTIONS_JSON" >/dev/null
}

cli_flag_for_var() {
  jq -r --arg v "$1" '._cli_map[$v] // empty' <<<"$FUNCTIONS_JSON"
}

list_api_functions() {
  compgen -A function ae_ \
    | sed 's/^ae_//' \
    | sort
}

function_help_line() {
  jq -r --arg fn "$1" '.[$fn].help // ""' <<<"$FUNCTIONS_JSON"
}

function_vars() {
  local fn="$1" type="$2"
  jq -r --arg fn "$fn" --arg t "$type" '.[$fn][$t][]?' <<<"$FUNCTIONS_JSON"
}

function_exists() {
  declare -F "$1" >/dev/null
}

validate_function_inputs() {
  local fn="$AE_API_FUNCTION"
  local missing=()

  while read -r var; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done < <(function_vars "$fn" required)

  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: Missing required arguments for '$fn':" >&2
    for var in "${missing[@]}"; do
      printf '  %s\n' "$(cli_flag_for_var "$var")" >&2
    done
    exit 64
  fi
}



#######################################
# AE-API Wrappers
#######################################
ae_execute_object() {

  # check if object exists
  with_silence ae_get_object

  declare -A req=(
    [method]="POST"
    [endpoint]="/${AE_CLIENT}/executions"
    [payload]="$(build_payload)"
  )
  local run_id status result

  # execute task
  result=$(rest_api req)
  echo "$result" 
  run_id="$(jq -r '.body.run_id // empty' <<<"$result")"

  [[ -n "$run_id" ]] || { echo "ERROR: No run_id returned" >&2; exit 30; }

  start_ts="$(date +%s)"

  # wait until status != 1572 (Generating)
  status=1572
  while (( status == 1572 )); do 
    sleep 2

    (( $(date +%s) - start_ts >= AE_EXEC_TIMEOUT )) && {
      echo "ERROR: Timeout waiting for 'Generating' (1572) to end" >&2
      exit 40
    }
    
    result="$(ae_get_execution "$run_id")" 
    status="$(hlp_get_ae_status_code "$result")"

  done
    
  if (( status < 1800 || status >= 1900 )); then
    debug "-AE-" "Execution successfully finished 'Generating' status"
  elif (( status == 1820 )); then
    log_error "-AE-" "Error during generation of task $AE_OBJECT_NAME: $status"
    echo "Error during generation of task $AE_OBJECT_NAME: $status" >&2
    exit 70
  fi

  # AE_EXEC_NOWAIT: don't wait for task to finish
  if $AE_EXEC_NOWAIT; then
    log "-AE-" "Nowait enabled – skipping final status evaluation"
    #echo "Nowait enabled – skipping final status evaluation"
    exit 0
  fi

  sleep 2

  result="$(ae_get_execution "$run_id")" 
  status="$(hlp_get_ae_status_code "$result")"
  
  while (( status < 1800 )); do
    sleep 10
    result="$(ae_get_execution "$run_id")" 
    status="$(hlp_get_ae_status_code "$result")"
  done

  if $AE_IGNORE_FINAL_STATUS; then
    log "-AE-" "Final status $status ignored"
    #echo "Final status $status ignored"
    exit 0
  fi

  state="$(hlp_ae_resolve_state "$status")"

  # Final evaluation
  if [[ $state == "FAILURE" ]]; then
    log_error "-AE-" "Execution of ${AE_OBJECT_NAME} ($run_id) failed with status $status"
    echo "ERROR: Execution failed with status $status" >&2
    exit 70
  else
    log "-AE-" "Execution of ${AE_OBJECT_NAME} ($run_id) finished successfully (status=$status)"
    #echo "Execution finished successfully (status=$status)"
    exit 0
  fi  
}

ae_get_execution() {
  declare -A req=(
    [method]="GET"
    [endpoint]="/${AE_CLIENT}/executions/$1"
  )
  rest_api req
}

ae_get_system_health() {
  declare -A req=(
    [method]="GET"
    [endpoint]="/0/system/health"
  )
  rest_api req
}

ae_ping() {
  declare -A req=(
    [method]="GET"
    [endpoint]="/ping"
  )
  rest_api req
}

ae_get_object() {
  declare -A req=(
    [method]="GET"
    [endpoint]="/${AE_CLIENT}/objects/${AE_OBJECT_NAME}"
  )
  rest_api req
}


#######################################
# Status helpers
#######################################
hlp_get_ae_status_code() {
  local status
  status=$(jq -r '.body.status // empty' <<<"$1") || {
    echo "ERROR: Status missing" >&2
    exit 50
  }
  echo $status
}

hlp_ae_is_generating() {
  [[ "$1" == "1572" ]]
}

hlp_ae_resolve_state() {
  local status="$1"

  # Special singleton states first
  case "$status" in
    1572) echo "GENERATING"; return ;;
  esac

  # Range-based semantics
  if (( status >= 1900 && status < 2000 )); then
    echo "SUCCESS"
  elif (( status >= 1800 && status < 1900 )); then
    echo "FAILURE"
  elif (( status >= 1700 && status < 1800 )); then
    echo "ENDING"
  elif (( status >= 1600 && status < 1700 )); then
    echo "RUNNING"
  elif (( status >= 1500 && status < 1600 )); then
    echo "WAITING"
  else
    echo "UNKNOWN"
  fi
}



#######################################
# MAIN
#######################################
main "$@"