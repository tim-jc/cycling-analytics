#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${DASHBOARD_LOG:-${PROJECT_DIR}/dashboard_refresh.log}"
RENDER_SCRIPT="${DASHBOARD_SCRIPT:-${PROJECT_DIR}/render_dashboard.R}"
RSCRIPT="${RSCRIPT:-/Library/Frameworks/R.framework/Versions/4.4-arm64/Resources/bin/Rscript}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}

log "Dashboard refresh wrapper starting."

if [[ ! -x "${RSCRIPT}" ]]; then
  log "Rscript not executable at ${RSCRIPT}"
  exit 127
fi

if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -s "${RSCRIPT}" "${RENDER_SCRIPT}" >> "${LOG_FILE}" 2>&1
else
  "${RSCRIPT}" "${RENDER_SCRIPT}" >> "${LOG_FILE}" 2>&1
fi

status=$?
log "Dashboard refresh wrapper finished with status ${status}."
exit "${status}"
