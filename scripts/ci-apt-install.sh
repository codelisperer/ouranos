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
# Only the network part runs under that outer timeout. Packages are downloaded first, with
# --download-only, which is safe to cut off and resumes from apt's cache on the next attempt.
# They are then installed from the cache with --no-download, with no outer timeout: that part does
# no network I/O, and cutting off dpkg while it unpacks or configures can leave packages
# half-configured. A slow mirror on #880's first run hit the 240 s limit twice during an install.
# `apt-get update` runs with --error-on=any: without it, update exits 0 even when every index
# fails to download, so a stalled mirror was only noticed at the install.
# The calling step also has its own timeout-minutes, so the worst case fails this step, with a
# message, well inside the job's limit.
#
# A SLOW MIRROR FAILS THE SAME WAY (#889). On one run the mirror served about 30-60 KB/s, and
# 61 MB of packages did not finish in three attempts. Before each download attempt this script
# prints how much is still to fetch, so a log shows whether the mirror was slow (the figure
# falls between attempts) or unreachable (it does not).
#
# THE DOWNLOADED PACKAGES CAN BE CACHED (#889). When CI_APT_ARCHIVE_CACHE names a directory,
# the .deb files in it are copied into apt's archive cache before the download, and apt fetches
# only what is missing or has changed: it checks each file against the package index, so a
# stale file is downloaded again, not installed. After the download the directory is replaced
# with the files this run used, so it does not grow. The directory belongs to the runner's
# user, which lets actions/cache save and restore it; /var/cache/apt/archives belongs to root.
# An empty or missing directory means a full download, as without the cache.
#
# It prints how long the installs took, how much was downloaded and how much came from the
# cache, as a job notice, so the cost is measured on every run.

set -euo pipefail

apt_opts=(-o Acquire::Retries=3
          -o Acquire::http::Timeout=30
          -o Acquire::https::Timeout=30
          -o DPkg::Lock::Timeout=120)

# The message for a network step that did not succeed in three attempts.
give_up() {
  echo "::error::apt did not succeed after 3 attempts: $*. The Ubuntu package mirror may be unreachable, stalled or too slow (#507, #889); rerun the job."
}

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
  give_up "$@"
  return 1
}

# Bytes apt still has to download to install "$@" (install arguments). It reads the local
# package indexes and the archive cache, not the network.
bytes_to_fetch() {
  sudo apt-get "${apt_opts[@]}" -qq --print-uris install -y "$@" 2>/dev/null \
    | awk '{ s += $3 } END { print s + 0 }'
}

megabytes() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'
}

# Download the packages for install arguments "$@", like with_retries, and print before each
# attempt how much is still to fetch.
download() {
  local i left
  for i in 1 2 3; do
    left=$(bytes_to_fetch "$@")
    echo "apt download attempt $i of 3: $(megabytes "$left") MB still to fetch"
    if timeout "$attempt_seconds" sudo apt-get "${apt_opts[@]}" install -y --download-only "$@"; then
      return 0
    fi
    echo "::warning::apt download attempt $i of 3 failed or took longer than ${attempt_seconds}s, with $(megabytes "$(bytes_to_fetch "$@")") of $(megabytes "$left") MB still to fetch: $*"
    if [ "$i" -lt 3 ]; then sleep $((i * 10)); fi
  done
  give_up "download of $* with $(megabytes "$(bytes_to_fetch "$@")") MB still to fetch"
  return 1
}

start=$(date +%s)

with_retries sudo apt-get "${apt_opts[@]}" update --error-on=any

# The webkit package is chosen by asking apt, not by letting an install fail, so a missing 4.1
# does not spend three attempts before 4.0 is tried.
if apt-cache show libwebkit2gtk-4.1-dev >/dev/null 2>&1; then
  webkit=libwebkit2gtk-4.1-dev
else
  webkit=libwebkit2gtk-4.0-dev
fi

launcher=(g++ pkg-config "$webkit")
keyring=(dbus gnome-keyring libsecret-1-0)

archives=/var/cache/apt/archives
cache=${CI_APT_ARCHIVE_CACHE:-}
needed=$(( $(bytes_to_fetch "${launcher[@]}") + $(bytes_to_fetch --no-install-recommends "${keyring[@]}") ))
cached=0
if [ -n "$cache" ] && compgen -G "$cache/*.deb" >/dev/null; then
  sudo cp "$cache"/*.deb "$archives"/
  cached=$(( needed - $(bytes_to_fetch "${launcher[@]}") - $(bytes_to_fetch --no-install-recommends "${keyring[@]}") ))
fi
echo "apt packages: $(megabytes "$needed") MB needed, $(megabytes "$cached") MB of it from the cache"

# Network: download only, under the outer timeout and the retries.
download "${launcher[@]}"
download --no-install-recommends "${keyring[@]}"

if [ -n "$cache" ]; then
  mkdir -p "$cache"
  rm -f "$cache"/*.deb
  cp "$archives"/*.deb "$cache"/
fi

# Local: install what was downloaded, with no outer timeout (see the header).
sudo apt-get "${apt_opts[@]}" install -y --no-download "${launcher[@]}"
sudo apt-get "${apt_opts[@]}" install -y --no-download --no-install-recommends "${keyring[@]}"

command -v dbus-run-session gnome-keyring-daemon g++ pkg-config >/dev/null

echo "::notice::apt packages ($webkit, keyring): $(( $(date +%s) - start ))s, $(megabytes "$(( needed - cached ))") MB downloaded, $(megabytes "$cached") MB from the cache"
