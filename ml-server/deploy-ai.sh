#!/usr/bin/env bash
# Usage: ml-server/deploy-ai.sh [verified-commit-sha]
set -Eeuo pipefail
umask 027

log() {
  printf '[ml-deploy] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  return 1
}

for command_name in git curl flock systemctl sudo; do
  command -v "$command_name" >/dev/null || fail "required command is missing: $command_name"
done

exec 9>/tmp/rallytrack-ml-deploy.lock
flock -n 9 || fail "another RallyTrack ML deployment is already running"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_ROOT="${RALLYTRACK_ROOT:-$DEFAULT_ROOT}"
AI_DIR="$DEPLOY_ROOT/aiAnalysis-server"
EXPECTED_SHA="${1:-}"
BRANCH="main"
PREVIOUS_REVISION=""
REQUIREMENTS_CHANGED=false
ROLLBACK_REQUIRED=false

[[ -d "$AI_DIR/.git" ]] || fail "AI repository is missing: $AI_DIR"
[[ -x "$AI_DIR/.venv/bin/python" ]] || fail "AI virtual environment is missing"
[[ -z "$(git -C "$AI_DIR" status --porcelain --untracked-files=normal)" ]] ||
  fail "AI repository has local changes; deployment refused"

for model_file in \
  tracknetv3/ckpts/TrackNet_best.pt \
  tracknetv3/ckpts/InpaintNet_best.pt \
  weights/yolov8n-pose.pt; do
  [[ -f "$AI_DIR/$model_file" ]] || fail "required model file is missing: $model_file"
done

wait_for_health() {
  local attempt
  for ((attempt = 1; attempt <= 36; attempt++)); do
    if systemctl is-active --quiet rallytrack-ai &&
      curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8000/health >/dev/null; then
      log "AI health check passed"
      return 0
    fi
    sleep 5
  done
  fail "AI health check failed"
}

rollback() {
  local exit_code="$1"
  trap - ERR
  set +e

  if [[ "$ROLLBACK_REQUIRED" != true ]]; then
    exit "$exit_code"
  fi

  log "deployment failed; restoring $PREVIOUS_REVISION"
  git -C "$AI_DIR" reset --hard "$PREVIOUS_REVISION"
  if [[ "$REQUIREMENTS_CHANGED" == true ]]; then
    "$AI_DIR/.venv/bin/pip" install -q -r "$AI_DIR/requirements.txt"
  fi
  sudo -n systemctl restart rallytrack-ai
  wait_for_health
  log "rollback attempted; inspect journalctl before retrying"
  exit "$exit_code"
}

trap 'rollback $?' ERR

PREVIOUS_REVISION="$(git -C "$AI_DIR" rev-parse HEAD)"
git -C "$AI_DIR" fetch --prune origin "$BRANCH"
if git -C "$AI_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$AI_DIR" switch "$BRANCH"
else
  git -C "$AI_DIR" switch --track -c "$BRANCH" "origin/$BRANCH"
fi

TARGET_REVISION="origin/$BRANCH"
if [[ -n "$EXPECTED_SHA" ]]; then
  git -C "$AI_DIR" cat-file -e "$EXPECTED_SHA^{commit}"
  git -C "$AI_DIR" merge-base --is-ancestor "$EXPECTED_SHA" "origin/$BRANCH" ||
    fail "$EXPECTED_SHA is not on origin/$BRANCH"
  TARGET_REVISION="$EXPECTED_SHA"
fi

if ! git -C "$AI_DIR" merge-base --is-ancestor "$TARGET_REVISION" HEAD; then
  git -C "$AI_DIR" merge --ff-only "$TARGET_REVISION"
fi
ROLLBACK_REQUIRED=true

if ! git -C "$AI_DIR" diff --quiet "$PREVIOUS_REVISION" HEAD -- requirements.txt; then
  REQUIREMENTS_CHANGED=true
  log "requirements changed; updating the existing virtual environment"
  "$AI_DIR/.venv/bin/pip" install -q -r "$AI_DIR/requirements.txt"
fi

"$AI_DIR/.venv/bin/pip" check
PYTHONPYCACHEPREFIX=/tmp/rallytrack-ai-deploy-pyc \
  "$AI_DIR/.venv/bin/python" -m compileall -q \
  "$AI_DIR/analysis" "$AI_DIR/config" "$AI_DIR/routers" "$AI_DIR/services" "$AI_DIR/main.py"
(
  cd "$AI_DIR"
  "$AI_DIR/.venv/bin/python" -m unittest discover -s tests -v
  "$AI_DIR/.venv/bin/python" -c 'from main import app; assert app.title == "RallyTrack AI Analysis Server"'
)

sudo -n systemctl restart rallytrack-ai
wait_for_health
ROLLBACK_REQUIRED=false
trap - ERR
log "AI deployment completed"
