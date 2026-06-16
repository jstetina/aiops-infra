#!/usr/bin/env bash
# Wrapper for the sync-rhoai-renovate-configs step (RHOAI only).
#
# Triggers the sync-renovate-configs GitHub Actions workflow in rhoai-konflux-central,
# monitors it to completion, and marks the step done. Unlike other steps, this step
# does not raise a PR — it completes synchronously.
#
# Exit codes:
#   0  Workflow succeeded — prints no URL (step is done); writes pipeline_state.json (status=done)
#   1  Workflow failed, was cancelled, or trigger failed; pipeline_state.json NOT written
#
# Known failure modes encoded here:
#   - HTTP 403: GITHUB_TOKEN lacks actions:write — exit 1 immediately
#   - HTTP 404: workflow or repo not found — exit 1 immediately
#   - Workflow failure: auto-retried once before failing
#   - Monitor timeout: exit 1 (step can be re-triggered by re-running)
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

JIRA_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-url) JIRA_URL="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$JIRA_URL" ]] && { echo "ERROR: --jira-url is required" >&2; exit 1; }

JIRA_ID="${JIRA_URL%/}"; JIRA_ID="${JIRA_ID##*/}"
WORKDIR="${WORKDIR:-$(pwd)/${JIRA_ID}}"
PIPELINE_STATE="${PIPELINE_STATE:-${WORKDIR}/pipeline_state.json}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

# Check if already done
CURRENT_STATUS=$(jq -r '.steps.renovate_sync.status // "pending"' "$PIPELINE_STATE")
if [[ "$CURRENT_STATUS" == "done" ]]; then
  echo "renovate_sync already marked done in pipeline state."
  exit 0
fi

# Dry-run bypass — workflow requires GitHub App secrets unavailable on forks
if [[ "${ONBOARD_DRY_RUN:-false}" == "true" ]]; then
  echo "ONBOARD_DRY_RUN=true — skipping workflow trigger, marking renovate_sync as done."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label   "renovate-sync-done" \
    --remove-label "renovate-sync-triggered" \
    --comment "[step:renovate_sync] Skipped (ONBOARD_DRY_RUN=true). Renovate sync workflow not triggered." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step renovate_sync --status done
  exit 0
fi

RKC_URL="${RHOAI_KONFLUX_CENTRAL_REPO_URL:-https://github.com/red-hat-data-services/konflux-central.git}"
RKC_PATH=$(echo "$RKC_URL" | sed 's|https://github.com/||;s|\.git$||')
WORKFLOW_FILE=".github/workflows/sync-renovate-configs.yml"
WORKFLOW_REF="main"

echo "RKC_URL       : $RKC_URL"
echo "WORKFLOW_FILE : $WORKFLOW_FILE"
echo "Triggering sync-renovate-configs workflow..."

trigger_workflow() {
  uv run --script "$SCRIPTS_DIR/run_github_workflow.py" trigger \
    --repo-url "$RKC_URL" \
    --workflow "$WORKFLOW_FILE" \
    --ref      "$WORKFLOW_REF" \
    --input    "dry_run=false" \
    --input    "renovate-config=all"
}

# Trigger with error classification
RUN_ID=""
for attempt in 1 2 3; do
  TRIGGER_OUT=$(trigger_workflow 2>/tmp/sync_trigger_err.txt) && {
    RUN_ID="$TRIGGER_OUT"
    break
  }
  ERR_CONTENT=$(cat /tmp/sync_trigger_err.txt 2>/dev/null || echo "")
  if echo "$ERR_CONTENT" | grep -q "403"; then
    echo "ERROR: HTTP 403 — GITHUB_TOKEN needs 'actions:write' scope." >&2; exit 1
  fi
  if echo "$ERR_CONTENT" | grep -q "404"; then
    echo "ERROR: HTTP 404 — workflow or repo not found at ${WORKFLOW_FILE}." >&2; exit 1
  fi
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not trigger sync-renovate-configs after 3 attempts." >&2
    cat /tmp/sync_trigger_err.txt >&2
    exit 1
  }
  sleep 10
done

RUN_URL="https://github.com/${RKC_PATH}/actions/runs/${RUN_ID}"
echo "Workflow triggered. Run ID: $RUN_ID"
echo "Run URL: $RUN_URL"

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "renovate-sync-triggered" \
  --comment "sync-renovate-configs workflow triggered (Run #${RUN_ID}).

Inputs: dry_run=false, renovate-config=all

Workflow run: ${RUN_URL}

Monitoring in progress (max 30 minutes)..." || true

# Monitor (max 30 minutes)
MONITOR_OUTPUT=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" monitor \
  --repo-url      "$RKC_URL" \
  --run-id        "$RUN_ID" \
  --timeout       30 \
  --poll-interval 60 2>/dev/null || echo "status=failure")
WORKFLOW_STATUS="${MONITOR_OUTPUT#status=}"

if [[ "$WORKFLOW_STATUS" == "success" ]]; then
  echo "Workflow run ${RUN_ID} completed successfully."

  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label   "renovate-sync-done" \
    --remove-label "renovate-sync-triggered" \
    --comment "[step:renovate_sync] sync-renovate-configs workflow completed successfully.

Run URL: ${RUN_URL}

Renovate config has been synced to all registered component repositories." || true

  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step renovate_sync --status done

  exit 0
fi

if [[ "$WORKFLOW_STATUS" == "failure" ]]; then
  # Auto-retry once
  echo "Workflow run ${RUN_ID} FAILED. Auto-retrying once..."
  RUN_ID2=$(trigger_workflow 2>/dev/null || echo "")
  if [[ -n "$RUN_ID2" ]]; then
    RUN_URL2="https://github.com/${RKC_PATH}/actions/runs/${RUN_ID2}"
    MONITOR_OUTPUT2=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" monitor \
      --repo-url      "$RKC_URL" \
      --run-id        "$RUN_ID2" \
      --timeout       30 \
      --poll-interval 60 2>/dev/null || echo "status=failure")
    if [[ "${MONITOR_OUTPUT2#status=}" == "success" ]]; then
      uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
        --add-label   "renovate-sync-done" \
        --remove-label "renovate-sync-triggered" \
        --comment "[step:renovate_sync] sync-renovate-configs workflow completed (retry run #${RUN_ID2}).
Run URL: ${RUN_URL2}" || true
      bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
        --state "$PIPELINE_STATE" --step renovate_sync --status done
      exit 0
    fi
  fi
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label   "renovate-sync-failed" \
    --remove-label "renovate-sync-triggered" \
    --comment "sync-renovate-configs workflow failed on second attempt.
Run URL: ${RUN_URL}
Re-run the pipeline to retry." || true
  echo "ERROR: sync-renovate-configs workflow failed on both attempts." >&2; exit 1
fi

if [[ "$WORKFLOW_STATUS" == "cancelled" ]]; then
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --remove-label "renovate-sync-triggered" \
    --comment "sync-renovate-configs workflow run #${RUN_ID} was cancelled.
Run URL: ${RUN_URL}" || true
  echo "ERROR: Workflow run ${RUN_ID} was cancelled." >&2; exit 1
fi

# timeout case
uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --comment "sync-renovate-configs workflow run #${RUN_ID} monitoring timed out after 30 minutes.
The run may still be completing.
Run URL: ${RUN_URL}" || true
echo "ERROR: Workflow run ${RUN_ID} did not complete within 30 minutes." >&2; exit 1
