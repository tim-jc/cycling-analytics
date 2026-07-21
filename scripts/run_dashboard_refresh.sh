#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${DASHBOARD_LOG:-${PROJECT_DIR}/dashboard_refresh.log}"
RENDER_SCRIPT="${DASHBOARD_SCRIPT:-${PROJECT_DIR}/render_dashboard.R}"
RSCRIPT="${RSCRIPT:-}"
LOCK_DIR="${DASHBOARD_LOCK_DIR:-/tmp/cycling-analytics-dashboard.lock}"

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export LANG="${LANG:-en_GB.UTF-8}"
export LC_ALL="${LC_ALL:-en_GB.UTF-8}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}

elapsed_seconds() {
  local started_at="$1"
  local finished_at

  finished_at="$(date +%s)"
  printf '%s' "$((finished_at - started_at))"
}

release_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

resolve_rscript() {
  local candidates=(
    "/Library/Frameworks/R.framework/Resources/bin/Rscript"
    "/Library/Frameworks/R.framework/Versions/Current/Resources/bin/Rscript"
    "/opt/homebrew/bin/Rscript"
    "/usr/local/bin/Rscript"
    "/usr/bin/Rscript"
  )

  if [[ -n "${RSCRIPT}" ]]; then
    return
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      RSCRIPT="${candidate}"
      return
    fi
  done

  if command -v Rscript >/dev/null 2>&1; then
    RSCRIPT="$(command -v Rscript)"
    return
  fi
}

initialise_started_at="$(date +%s)"
log "Stage=Initialise status=started cwd=$(pwd)"
log "Environment PATH=${PATH}"
log "Environment HOME=${HOME:-}"
log "Environment SHELL=${SHELL:-}"
log "Project dir=${PROJECT_DIR}"
log "Render script=${RENDER_SCRIPT}"
log "Log file=${LOG_FILE}"

resolve_rscript

log "Rscript=${RSCRIPT}"

if [[ ! -x "${RSCRIPT}" ]]; then
  log "Stage=Initialise status=failed elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") exit_code=127 cwd=$(pwd)"
  log "Rscript not executable at ${RSCRIPT}"
  exit 127
fi

if [[ ! -r "${RENDER_SCRIPT}" ]]; then
  log "Stage=Initialise status=failed elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") exit_code=126 cwd=$(pwd)"
  log "Render script is not readable: ${RENDER_SCRIPT}"
  exit 126
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log "Stage=Initialise status=skipped elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") cwd=$(pwd)"
  log "Another dashboard refresh appears to be active: ${LOCK_DIR}"
  exit 0
fi

trap release_lock EXIT

cd "${PROJECT_DIR}" || {
  log "Stage=Initialise status=failed elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") exit_code=1 cwd=$(pwd)"
  log "Could not change directory to ${PROJECT_DIR}"
  exit 1
}

export RENV_PROJECT="${RENV_PROJECT:-${PROJECT_DIR}}"
export RENV_CONFIG_SANDBOX_ENABLED="${RENV_CONFIG_SANDBOX_ENABLED:-FALSE}"

log "Stage=Initialise status=success elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") cwd=$(pwd)"
log "Stage=RenderCommand status=started cwd=$(pwd) command='${RSCRIPT} - < ${RENDER_SCRIPT}'"

render_started_at="$(date +%s)"
set +e
"${RSCRIPT}" - < "${RENDER_SCRIPT}" >> "${LOG_FILE}" 2>&1
status=$?
set -e

if [[ "${status}" -eq 0 ]]; then
  log "Stage=RenderCommand status=success elapsed_seconds=$(elapsed_seconds "${render_started_at}") exit_code=${status} cwd=$(pwd)"
else
  log "Stage=RenderCommand status=failed elapsed_seconds=$(elapsed_seconds "${render_started_at}") exit_code=${status} cwd=$(pwd)"
  log "Failure context PATH=${PATH}"
  log "Failure context HOME=${HOME:-}"
  log "Failure context SHELL=${SHELL:-}"
  log "Failure context command='${RSCRIPT} - < ${RENDER_SCRIPT}'"
fi

log "Dashboard refresh wrapper finished with status ${status}."
exit "${status}"
