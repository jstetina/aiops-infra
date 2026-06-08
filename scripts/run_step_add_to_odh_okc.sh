#!/usr/bin/env bash
# Wrapper for the add-component-to-odh-konflux-central (okc) step — ODH variant.
#
# Generates PipelineRun YAMLs and raises a GitHub PR to odh-konflux-central.
#
# Exit codes:
#   0  PR raised — prints PR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure — stderr has error; pipeline_state.json NOT written
#   2  Component PipelineRun already exists — writes pipeline_state.json (status=done)
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

EXISTING_URL=$(jq -r '.steps.okc.pr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "PR already recorded in state: $EXISTING_URL"
  echo "PR_URL=$EXISTING_URL"
  exit 0
fi

YAML_FILE="$WORKDIR/component_onboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

eval "$(bash "$SCRIPTS_DIR/parse_component_details.sh" \
  --workdir     "$WORKDIR" \
  --jira-id     "$JIRA_ID" \
  --scripts-dir "$SCRIPTS_DIR")"

CONTEXT_PATH=$(grep -m1    'context_path:'    "$YAML_FILE" | awk '{print $2}')
DOCKERFILE_PATH=$(grep -m1 'dockerfile_path:' "$YAML_FILE" | awk '{print $2}')
BUILD_TYPE=$(grep -m1      'build_type:'      "$YAML_FILE" | awk '{print $2}')

if [[ "$COMPONENT_NAME" == *-ci ]]; then
  KONFLUX_COMPONENT_NAME="$COMPONENT_NAME"
else
  KONFLUX_COMPONENT_NAME="${COMPONENT_NAME}-ci"
fi
REPO_NAME="${REPO_URL##*/}"; REPO_NAME="${REPO_NAME%.git}"

OKC_URL="${ODH_KONFLUX_CENTRAL_REPO_URL:-https://github.com/opendatahub-io/odh-konflux-central.git}"
echo "ODH_KONFLUX_CENTRAL_REPO_URL=${ODH_KONFLUX_CENTRAL_REPO_URL:-(not set, using default)}"
echo "OKC_URL resolved to: $OKC_URL"
OKC_PATH=$(echo "$OKC_URL" | sed 's|https://github.com/||;s|\.git$||')

# Check for existing PipelineRun in fork (idempotency)
FORK_URL=$(uv run --script "$SCRIPTS_DIR/setup_github_fork.py" \
  --github-repo-url "$OKC_URL") || {
  echo "ERROR: Could not fork odh-konflux-central." >&2; exit 1
}

cd "$WORKDIR"
PLAYPEN_OUTPUT=$(bash "$SCRIPTS_DIR/setup_github_playpen.sh" \
  --src-url    "$OKC_URL" \
  --src-branch "main" \
  --dest-branch "$JIRA_ID" \
  --sparse-files "pipelineruns") || {
  echo "ERROR: Playpen setup for odh-konflux-central failed." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

# Detect prefetch method
eval "$(bash "$SCRIPTS_DIR/detect_prefetch_input.sh" \
  --repo-url "$REPO_URL" \
  --branch   "$REPO_BRANCH")" 2>/dev/null || true

# Generate PipelineRun YAMLs using the onboarder-workflow template if available,
# else use ensure_github_branch to create the branch with generated files
bash "$SCRIPTS_DIR/ensure_github_branch.sh" \
  --clone-dir          "$CLONE_DIR" \
  --branch             "$DEST_BRANCH" \
  --component-name     "$KONFLUX_COMPONENT_NAME" \
  --repo-name          "$REPO_NAME" \
  --repo-url           "$REPO_URL" \
  --repo-branch        "$REPO_BRANCH" \
  --context-path       "$CONTEXT_PATH" \
  --dockerfile-path    "$DOCKERFILE_PATH" \
  --quay-org           "$QUAY_ORG" \
  ${PREFETCH_INPUT:+--prefetch-input "$PREFETCH_INPUT"} \
  ${BUILD_TYPE:+--build-type "$BUILD_TYPE"} || {
  echo "ERROR: ensure_github_branch.sh failed for ODH OKC." >&2; exit 1
}

# Raise PR
PR_URL=""
for attempt in 1 2 3; do
  PR_URL=$(uv run --script "$SCRIPTS_DIR/raise_github_pr.py" \
    --src-url     "$OKC_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$OKC_URL" \
    --dest-branch "main" \
    --title       "Add ${KONFLUX_COMPONENT_NAME} PipelineRuns" \
    --description "Adds push and pull-request PipelineRun YAMLs for '${KONFLUX_COMPONENT_NAME}'.

Component repo: ${REPO_URL}
Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create PR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "okc-pr-raised" \
  --comment "GitHub PR raised to add '${KONFLUX_COMPONENT_NAME}' to odh-konflux-central.

PR URL: ${PR_URL}

Konflux CI will start building the component once this PR is merged." || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step okc \
  --status pr_raised --url "$PR_URL" --url-field pr_url

echo "PR_URL=${PR_URL}"
