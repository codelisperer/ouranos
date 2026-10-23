#!/usr/bin/env bash
# ci-apt-install.sh --- install the Linux CI jobs' packages with bounded waits (#507).
#
# Usage (CI only; it runs apt-get through sudo): scripts/ci-apt-install.sh
#
# Installs what the Linux jobs in .github/workflows/verify.yml need from apt:
#   - the webview launcher's build tools: g++, pkg-config and the WebKitGTK development package,
#     4.1 when the mirror has it and 4.0 otherwise, as hyperion/hyperion-view/build.sh probes;
#   - what scripts/with-secret-service.sh runs: dbus, gnome-keyring and libsecret-1-0 (#357).
#
# WHY IT EXISTS. apt-get stalled on the Ubuntu mirror three times in about 26 hours (#507), each
# time until the job's own limit cancelled it, which reads like a code failure until someone opens
# the step list. So every apt-get here runs with:
#   - Acquire::Retries, and connection timeouts for http and https, so one stuck download is
#     retried instead of waited on;
#   - DPkg::Lock::Timeout, so a lock held by the runner's own apt does not hang the step;
#   - an outer `timeout` per attempt, and up to three attempts with a pause between them.
# The calling step also has its own timeout-minutes, so the worst case fails this step, with a
# message, well inside the job's limit.
#
# It prints how long the installs took as a job notice, so the cost is measured on every run.

set -euo pipefail

apt_opts=(-o Acquire::Retries=3
          -o Acquire::http::Timeout=30
          -o Acquire::https::Timeout=30
          -o DPkg::Lock::Timeout=120)

# Run "$@" up to three times, each attempt limited to ATTEMPT_SECONDS.
attempt_seconds=${CI_APT_ATTEMPT_SECONDS:-240}
with_retries() {
  local i
  for i in 1 2 3; do
    if timeout "$attempt_seconds" "$@"; then
      return 0
    fi
    echo "::warning::apt attempt $i of 3 failed or took longer than ${attempt_seconds}s: $*"
    if [ "$i" -lt 3 ]; then sleep $((i * 10)); fi
  done
  echo "::error::apt did not succeed after 3 attempts: $*. The Ubuntu package mirror may be unreachable or stalled (#507); rerun the job."
  return 1
}

start=$(date +%s)

with_retries sudo apt-get "${apt_opts[@]}" update

# The webkit package is chosen by asking apt, not by letting an install fail, so a missing 4.1
# does not spend three attempts before 4.0 is tried.
if apt-cache show libwebkit2gtk-4.1-dev >/dev/null 2>&1; then
  webkit=libwebkit2gtk-4.1-dev
else
  webkit=libwebkit2gtk-4.0-dev
fi

with_retries sudo apt-get "${apt_opts[@]}" install -y g++ pkg-config "$webkit"
with_retries sudo apt-get "${apt_opts[@]}" install -y --no-install-recommends \
  dbus gnome-keyring libsecret-1-0

command -v dbus-run-session gnome-keyring-daemon g++ pkg-config >/dev/null

echo "::notice::apt packages ($webkit, keyring): $(( $(date +%s) - start ))s"
