#!/usr/bin/env bash
# with-secret-service.sh --- run a command with a throwaway Secret Service (#357).
#
# Usage: scripts/with-secret-service.sh COMMAND [ARGS...]
#
# Runs COMMAND on a private D-Bus session bus with GNOME Keyring providing the Secret Service on
# it. The keyring is new, kept in a temporary directory, and unlocked with a random password that
# goes from /dev/urandom straight into the daemon's standard input: it is never put in a variable,
# an argument, the environment or a log. The directory is deleted when COMMAND exits, and this
# script exits with COMMAND's status.
#
# CI runs the gate through this on Linux so that hades/credentials's live tests have a store to
# use. On a developer's machine it runs those tests without touching the keyring you log in with:
# XDG_RUNTIME_DIR, XDG_DATA_HOME and XDG_CONFIG_HOME all point into the temporary directory, so
# the daemon started here cannot find or unlock the one your desktop runs.
#
#   OURANOS_TEST_REAL_CREDENTIAL_STORE=1 scripts/with-secret-service.sh \
#     sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
#
# Needs dbus-run-session (Debian and Ubuntu package dbus), gnome-keyring-daemon (gnome-keyring)
# and libsecret-1.so.0 (libsecret-1-0). Do not run it under `set -x`.

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 COMMAND [ARGS...]" >&2
  exit 2
fi

if [ -z "${OURANOS_SECRET_SERVICE_DIR:-}" ]; then
  for program in dbus-run-session gnome-keyring-daemon; do
    if ! command -v "$program" >/dev/null; then
      echo "$0: $program is not installed; it comes with the package named in this script's header" >&2
      exit 2
    fi
  done
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  mkdir -m 700 "$dir/runtime" "$dir/data" "$dir/config"
  status=0
  OURANOS_SECRET_SERVICE_DIR="$dir" \
    XDG_RUNTIME_DIR="$dir/runtime" XDG_DATA_HOME="$dir/data" XDG_CONFIG_HOME="$dir/config" \
    dbus-run-session -- "$0" "$@" || status=$?
  exit "$status"
fi

# Inside the private session. --unlock reads the password from standard input until it ends, and
# with no login keyring yet it creates one with that password and makes it the default.
head -c 32 /dev/urandom | base64 | tr -d '\n' \
  | gnome-keyring-daemon --unlock --components=secrets >/dev/null
exec "$@"
