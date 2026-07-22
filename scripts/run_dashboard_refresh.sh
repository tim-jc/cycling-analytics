#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${DASHBOARD_LOG:-${PROJECT_DIR}/dashboard_refresh.log}"
RENDER_SCRIPT="${DASHBOARD_SCRIPT:-${PROJECT_DIR}/render_dashboard.R}"
RSCRIPT="${RSCRIPT:-}"
LOCK_DIR="${DASHBOARD_LOCK_DIR:-/tmp/cycling-analytics-dashboard.lock}"
RUNTIME_PROJECT_DIR=""
RUNTIME_RENDER_SCRIPT=""
PUBLISH_COMMIT=""
NOTIFICATION_CONTEXT_FILE=""

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

cleanup_runtime_project() {
  if [[ -n "${RUNTIME_PROJECT_DIR}" && -d "${RUNTIME_PROJECT_DIR}" ]]; then
    rm -rf "${RUNTIME_PROJECT_DIR}"
  fi
}

cleanup_on_exit() {
  release_lock
  cleanup_runtime_project
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

prepare_runtime_project() {
  local started_at

  started_at="$(date +%s)"
  RUNTIME_PROJECT_DIR="/tmp/cycling-analytics-runtime-$$"
  RUNTIME_RENDER_SCRIPT="${RUNTIME_PROJECT_DIR}/render_dashboard.R"
  NOTIFICATION_CONTEXT_FILE="${RUNTIME_PROJECT_DIR}/dashboard_notification_context.txt"

  log "Stage=Prepare runtime status=started cwd=$(pwd) runtime_project=${RUNTIME_PROJECT_DIR}"

  rm -rf "${RUNTIME_PROJECT_DIR}"
  mkdir -p "${RUNTIME_PROJECT_DIR}"
  chmod 700 "${RUNTIME_PROJECT_DIR}" || true

  rsync -a \
    --exclude ".git" \
    --exclude "dashboard_refresh.log" \
    --exclude "renv/library" \
    --exclude "renv/staging" \
    --exclude "renv/sandbox" \
    "${PROJECT_DIR}/" \
    "${RUNTIME_PROJECT_DIR}/" >> "${LOG_FILE}" 2>&1

  status=$?
  if [[ "${status}" -ne 0 ]]; then
    log "Stage=Prepare runtime status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=${status} cwd=$(pwd)"
    return "${status}"
  fi

  if [[ ! -r "${RUNTIME_RENDER_SCRIPT}" ]]; then
    log "Stage=Prepare runtime status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=$(pwd)"
    log "Runtime render script is not readable: ${RUNTIME_RENDER_SCRIPT}"
    return 1
  fi

  log "Stage=Prepare runtime status=success elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=$(pwd)"
}

copy_rendered_dashboard() {
  local started_at
  local runtime_output
  local project_output

  started_at="$(date +%s)"
  runtime_output="${RUNTIME_PROJECT_DIR}/docs/index.html"
  project_output="${PROJECT_DIR}/docs/index.html"

  log "Stage=Copy output status=started cwd=$(pwd) source=${runtime_output} target=${project_output}"

  if [[ ! -r "${runtime_output}" ]]; then
    log "Stage=Copy output status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=$(pwd)"
    log "Rendered dashboard was not created: ${runtime_output}"
    return 1
  fi

  mkdir -p "$(dirname "${project_output}")"
  cp "${runtime_output}" "${project_output}"
  status=$?
  if [[ "${status}" -ne 0 ]]; then
    log "Stage=Copy output status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=${status} cwd=$(pwd)"
    return "${status}"
  fi

  log "Stage=Copy output status=success elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=$(pwd)"
}

run_git() {
  local started_at
  local status

  started_at="$(date +%s)"
  log "Git command started: cwd=${PROJECT_DIR}; command=git $*"

  set +e
  git -C "${PROJECT_DIR}" "$@" >> "${LOG_FILE}" 2>&1
  status=$?
  set -e

  log "Git command finished: status=${status}; elapsed_seconds=$(elapsed_seconds "${started_at}"); command=git $*"
  return "${status}"
}

publish_dashboard() {
  local started_at

  started_at="$(date +%s)"
  log "Stage=Publish to Git status=started cwd=${PROJECT_DIR}"

  if ! run_git add "docs/index.html"; then
    log "Stage=Publish to Git status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=${PROJECT_DIR}"
    return 1
  fi

  if run_git diff --cached --quiet; then
    log "No dashboard changes to commit."
    if ! run_git push origin main; then
      log "Stage=Publish to Git status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=${PROJECT_DIR}"
      return 1
    fi

    PUBLISH_COMMIT="none"
    log "Stage=Publish to Git status=success elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=${PROJECT_DIR}"
    return 0
  fi

  if ! run_git commit -m "auto commit from cron / Rscript"; then
    log "Stage=Publish to Git status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=${PROJECT_DIR}"
    return 1
  fi

  PUBLISH_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>> "${LOG_FILE}")"

  if ! run_git push origin main; then
    log "Stage=Publish to Git status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=1 cwd=${PROJECT_DIR}"
    return 1
  fi

  log "Published dashboard to GitHub."
  log "Stage=Publish to Git status=success elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=${PROJECT_DIR}"
}

read_renviron_value() {
  local key="$1"
  local file="${PROJECT_DIR}/.Renviron"

  if [[ ! -r "${file}" ]]; then
    return
  fi

  awk -F '=' -v key="${key}" '
    $1 == key {
      sub(/^[^=]*=/, "", $0)
      print $0
      exit
    }
  ' "${file}"
}

send_notification() {
  local started_at
  local topic
  local title
  local tags
  local body_file
  local publish_line

  started_at="$(date +%s)"
  log "Stage=Notify status=started cwd=${PROJECT_DIR}"

  if ! command -v curl >/dev/null 2>&1; then
    log "Stage=Notify status=skipped elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=${PROJECT_DIR}"
    log "curl not found; notification skipped."
    return 0
  fi

  topic="$(read_renviron_value "NTFY_TOPIC")"
  if [[ -z "${topic}" ]]; then
    topic="cycling-analytics"
  fi

  if [[ "${PUBLISH_COMMIT}" == "none" ]]; then
    title="Dashboard checked"
    tags="bike,mag"
    publish_line="Publish: no dashboard changes"
  else
    title="Dashboard published"
    tags="bike,white_check_mark"
    publish_line="Publish: commit ${PUBLISH_COMMIT} pushed"
  fi

  body_file="${RUNTIME_PROJECT_DIR}/dashboard_notification_body.txt"

  if [[ -r "${NOTIFICATION_CONTEXT_FILE}" ]]; then
    log "Notification context file found: ${NOTIFICATION_CONTEXT_FILE}"
    awk -v publish_line="${publish_line}" '
      NR == 4 {
        print publish_line
      }
      {
        print
      }
    ' "${NOTIFICATION_CONTEXT_FILE}" > "${body_file}"
  else
    log "Notification context file missing: ${NOTIFICATION_CONTEXT_FILE}; using fallback body."
    {
      printf 'Rendered: %s\n' "$(date '+%d %b %H:%M')"
      printf '%s\n' "${publish_line}"
      printf 'Next refresh: unknown\n'
    } > "${body_file}"
  fi

  curl \
    -fsS \
    -H "Title: ${title}" \
    -H "Tags: ${tags}" \
    -H "Click: https://tim-jc.github.io/cycling-analytics" \
    --data-binary "@${body_file}" \
    "https://ntfy.sh/${topic}" >> "${LOG_FILE}" 2>&1

  status=$?
  if [[ "${status}" -eq 0 ]]; then
    log "Stage=Notify status=success elapsed_seconds=$(elapsed_seconds "${started_at}") cwd=${PROJECT_DIR}"
  else
    log "Stage=Notify status=failed elapsed_seconds=$(elapsed_seconds "${started_at}") exit_code=${status} cwd=${PROJECT_DIR}"
  fi

  return "${status}"
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

trap cleanup_on_exit EXIT

cd "${PROJECT_DIR}" || {
  log "Stage=Initialise status=failed elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") exit_code=1 cwd=$(pwd)"
  log "Could not change directory to ${PROJECT_DIR}"
  exit 1
}

if ! prepare_runtime_project; then
  status=1
  log "Dashboard refresh wrapper finished with status ${status}."
  exit "${status}"
fi

export RENV_PROJECT="${RUNTIME_PROJECT_DIR}"
export CYCLING_ANALYTICS_PROJECT_DIR="${RUNTIME_PROJECT_DIR}"
export RENV_CONFIG_SANDBOX_ENABLED="${RENV_CONFIG_SANDBOX_ENABLED:-FALSE}"
export DASHBOARD_LOG_REDIRECTED="TRUE"
export DASHBOARD_SKIP_PUBLISH="TRUE"
export DASHBOARD_SKIP_NOTIFY="TRUE"
export DASHBOARD_LOG="${LOG_FILE}"
export DASHBOARD_NOTIFICATION_CONTEXT_FILE="${NOTIFICATION_CONTEXT_FILE}"

log "Stage=Initialise status=success elapsed_seconds=$(elapsed_seconds "${initialise_started_at}") cwd=$(pwd)"
log "Stage=RenderCommand status=started cwd=${RUNTIME_PROJECT_DIR} command='${RSCRIPT} - < ${RUNTIME_RENDER_SCRIPT}'"

render_started_at="$(date +%s)"
set +e
cd "${RUNTIME_PROJECT_DIR}"
"${RSCRIPT}" - < "${RUNTIME_RENDER_SCRIPT}" >> "${LOG_FILE}" 2>&1
status=$?
set +e

if [[ "${status}" -eq 0 ]]; then
  log "Stage=RenderCommand status=success elapsed_seconds=$(elapsed_seconds "${render_started_at}") exit_code=${status} cwd=${RUNTIME_PROJECT_DIR}"
else
  log "Stage=RenderCommand status=failed elapsed_seconds=$(elapsed_seconds "${render_started_at}") exit_code=${status} cwd=${RUNTIME_PROJECT_DIR}"
  log "Failure context PATH=${PATH}"
  log "Failure context HOME=${HOME:-}"
  log "Failure context SHELL=${SHELL:-}"
  log "Failure context command='${RSCRIPT} - < ${RUNTIME_RENDER_SCRIPT}'"
  log "Dashboard refresh wrapper finished with status ${status}."
  exit "${status}"
fi

if ! copy_rendered_dashboard; then
  status=1
  log "Dashboard refresh wrapper finished with status ${status}."
  exit "${status}"
fi

if ! publish_dashboard; then
  status=1
  log "Dashboard refresh wrapper finished with status ${status}."
  exit "${status}"
fi

if ! send_notification; then
  status=1
  log "Dashboard refresh wrapper finished with status ${status}."
  exit "${status}"
fi

log "Dashboard refresh wrapper finished with status ${status}."
exit "${status}"
