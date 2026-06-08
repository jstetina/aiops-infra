#!/usr/bin/env bash
# Atomically updates a step's status (and optional URL) in pipeline_state.json.
#
# Usage:
#   bash scripts/update_pipeline_state.sh \
#     --state   <path>             \
#     --step    <step_key>         \
#     --status  <mr_raised|pr_raised|done|skipped> \
#     [--url      <url>]           \
#     [--url-field <mr_url|pr_url>]
#
# Exit codes: 0 success, 1 error
set -euo pipefail

STATE_FILE=""
STEP=""
STATUS=""
URL=""
URL_FIELD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)     STATE_FILE="$2"; shift 2 ;;
    --step)      STEP="$2";       shift 2 ;;
    --status)    STATUS="$2";     shift 2 ;;
    --url)       URL="$2";        shift 2 ;;
    --url-field) URL_FIELD="$2";  shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$STATE_FILE" ]] && { echo "ERROR: --state is required" >&2; exit 1; }
[[ -z "$STEP" ]]       && { echo "ERROR: --step is required"  >&2; exit 1; }
[[ -z "$STATUS" ]]     && { echo "ERROR: --status is required" >&2; exit 1; }
[[ ! -f "$STATE_FILE" ]] && { echo "ERROR: state file not found: $STATE_FILE" >&2; exit 1; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP="${STATE_FILE}.tmp.$$"

if [[ -n "$URL" && -n "$URL_FIELD" ]]; then
  jq \
    --arg step   "$STEP"   \
    --arg status "$STATUS" \
    --arg url    "$URL"    \
    --arg field  "$URL_FIELD" \
    --arg ts     "$NOW"    \
    '.steps[$step].status = $status
     | .steps[$step][$field] = $url
     | .last_status_change_at = $ts' \
    "$STATE_FILE" > "$TMP"
else
  jq \
    --arg step   "$STEP"   \
    --arg status "$STATUS" \
    --arg ts     "$NOW"    \
    '.steps[$step].status = $status
     | .last_status_change_at = $ts' \
    "$STATE_FILE" > "$TMP"
fi

mv "$TMP" "$STATE_FILE"
