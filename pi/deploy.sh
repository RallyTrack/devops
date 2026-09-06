#!/usr/bin/env bash
# Usage: pi/deploy.sh [backend|frontend|devops|all] [verified-commit-sha]
set -Eeuo pipefail
umask 027

log() {
  printf '[pi-deploy] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  return 1
}

for command_name in git docker curl flock; do
  command -v "$command_name" >/dev/null || fail "required command is missing: $command_name"
done

exec 9>/tmp/rallytrack-pi-deploy.lock
flock -n 9 || fail "another RallyTrack Pi deployment is already running"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_ROOT="${RALLYTRACK_ROOT:-$DEFAULT_ROOT}"
DEVOPS_DIR="$DEPLOY_ROOT/devops"
ENV_FILE="${RALLYTRACK_ENV_FILE:-$DEVOPS_DIR/.env}"
COMPONENT="${1:-all}"
EXPECTED_SHA="${2:-}"

case "$COMPONENT" in
  backend|frontend|devops|all) ;;
  *) fail "component must be backend, frontend, devops, or all" ;;
esac

[[ -f "$ENV_FILE" ]] || fail "environment file is missing: $ENV_FILE"
[[ -f "$DEVOPS_DIR/docker-compose.pi.yml" ]] || fail "Pi compose file is missing"

declare -A BRANCHES=(
  [backend]="main"
  [frontend]="develop"
  [devops]="main"
)
declare -A PREVIOUS_REVISIONS=()
declare -A PREVIOUS_IMAGES=()
UPDATED_REPOSITORIES=()
BUILT_SERVICES=()
ROLLBACK_REQUIRED=false

check_clean_repository() {
  local repository="$1"
  local directory="$DEPLOY_ROOT/$repository"
  [[ -d "$directory/.git" ]] || fail "repository is missing: $directory"
  [[ -z "$(git -C "$directory" status --porcelain --untracked-files=normal)" ]] ||
    fail "$repository has local changes; deployment refused"
}

update_repository() {
  local repository="$1"
  local branch="${BRANCHES[$repository]}"
  local directory="$DEPLOY_ROOT/$repository"
  local target_revision="origin/$branch"

  check_clean_repository "$repository"
  PREVIOUS_REVISIONS["$repository"]="$(git -C "$directory" rev-parse HEAD)"
  UPDATED_REPOSITORIES+=("$repository")

  log "fetching $repository/$branch"
  git -C "$directory" fetch --prune origin "$branch"

  if git -C "$directory" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$directory" switch "$branch"
  else
    git -C "$directory" switch --track -c "$branch" "origin/$branch"
  fi

  if [[ -n "$EXPECTED_SHA" && "$repository" == "$COMPONENT" ]]; then
    git -C "$directory" cat-file -e "$EXPECTED_SHA^{commit}"
    git -C "$directory" merge-base --is-ancestor "$EXPECTED_SHA" "origin/$branch" ||
      fail "$EXPECTED_SHA is not on origin/$branch"
    target_revision="$EXPECTED_SHA"
  fi

  if git -C "$directory" merge-base --is-ancestor "$target_revision" HEAD; then
    log "$repository already contains the verified revision"
  else
    git -C "$directory" merge --ff-only "$target_revision"
  fi
}

capture_image() {
  local service="$1"
  local image="rallytrack/$service:local"
  PREVIOUS_IMAGES["$service"]="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  BUILT_SERVICES+=("$service")
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local attempts="${3:-36}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --fail --silent --show-error --max-time 5 "$url" >/dev/null; then
      log "$name health check passed"
      return 0
    fi
    sleep 5
  done
  fail "$name health check failed: $url"
}

rollback() {
  local exit_code="$1"
  trap - ERR
  set +e

  if [[ "$ROLLBACK_REQUIRED" != true ]]; then
    exit "$exit_code"
  fi

  log "deployment failed; restoring the previous revision"
  for repository in "${UPDATED_REPOSITORIES[@]}"; do
    git -C "$DEPLOY_ROOT/$repository" reset --hard "${PREVIOUS_REVISIONS[$repository]}"
  done

  local rebuild_previous=false
  local service
  for service in "${BUILT_SERVICES[@]}"; do
    if [[ -n "${PREVIOUS_IMAGES[$service]:-}" ]]; then
      docker image tag "${PREVIOUS_IMAGES[$service]}" "rallytrack/$service:local"
    else
      rebuild_previous=true
    fi
  done

  local compose=(docker compose -p rallytrack -f "$DEVOPS_DIR/docker-compose.pi.yml" --env-file "$ENV_FILE")
  if [[ "$rebuild_previous" == true ]]; then
    for service in "${BUILT_SERVICES[@]}"; do
      "${compose[@]}" build "$service"
    done
  fi
  "${compose[@]}" up -d --no-build
  "${compose[@]}" ps
  log "rollback attempted; inspect service logs before retrying"
  exit "$exit_code"
}

trap 'rollback $?' ERR

if [[ "$COMPONENT" == "all" ]]; then
  update_repository backend
  update_repository frontend
  update_repository devops
else
  update_repository "$COMPONENT"
fi
ROLLBACK_REQUIRED=true

COMPOSE=(docker compose -p rallytrack -f "$DEVOPS_DIR/docker-compose.pi.yml" --env-file "$ENV_FILE")
"${COMPOSE[@]}" config --quiet

case "$COMPONENT" in
  backend)
    capture_image backend
    "${COMPOSE[@]}" build backend
    "${COMPOSE[@]}" up -d --no-build backend
    ;;
  frontend)
    capture_image frontend
    "${COMPOSE[@]}" build frontend
    "${COMPOSE[@]}" up -d --no-build frontend
    ;;
  devops|all)
    # Sequential builds keep peak memory usage predictable on the Pi.
    capture_image backend
    "${COMPOSE[@]}" build backend
    capture_image frontend
    "${COMPOSE[@]}" build frontend
    "${COMPOSE[@]}" up -d --no-build
    ;;
esac

if [[ "$COMPONENT" != "frontend" ]]; then
  wait_for_http backend http://127.0.0.1:8080/v3/api-docs
fi
if [[ "$COMPONENT" != "backend" ]]; then
  wait_for_http frontend http://127.0.0.1:8082/
fi

"${COMPOSE[@]}" ps
ROLLBACK_REQUIRED=false
trap - ERR
log "$COMPONENT deployment completed"
