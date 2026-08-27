#!/bin/sh
set -eu

runtime_uid="$(id -u)"
runtime_dir="${CYCLING_ANALYTICS_RUNTIME_DIR:-/tmp/cycling-analytics-${runtime_uid}}"

export CYCLING_ANALYTICS_RUNTIME_DIR="${runtime_dir}"
export HOME="${runtime_dir}/home"
export R_USER="${HOME}"
export XDG_CACHE_HOME="${runtime_dir}/cache"
export TMPDIR="${runtime_dir}/tmp"
export CYCLING_ANALYTICS_RENDER_DIR="${runtime_dir}/render"

umask 077
mkdir -p \
  "${HOME}" \
  "${XDG_CACHE_HOME}" \
  "${TMPDIR}" \
  "${CYCLING_ANALYTICS_RENDER_DIR}"

for writable_dir in \
  "${HOME}" \
  "${XDG_CACHE_HOME}" \
  "${TMPDIR}" \
  "${CYCLING_ANALYTICS_RENDER_DIR}"
do
  if [ ! -w "${writable_dir}" ]; then
    printf 'Runtime directory is not writable by uid %s: %s\n' \
      "${runtime_uid}" "${writable_dir}" >&2
    exit 1
  fi
done

if [ ! -d "${CYCLING_ANALYTICS_OUTPUT_DIR}" ] || \
   [ ! -w "${CYCLING_ANALYTICS_OUTPUT_DIR}" ]; then
  printf 'Dashboard output directory is not writable by uid %s: %s\n' \
    "${runtime_uid}" "${CYCLING_ANALYTICS_OUTPUT_DIR}" >&2
  exit 1
fi

exec "$@"
