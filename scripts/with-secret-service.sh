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
# the daemon started here runs with XDG_RUNTIME_DIR, XDG_DATA_HOME and XDG_CONFIG_HOME pointing
# into the temporary directory, so it cannot find or unlock the one your desktop runs. COMMAND
# itself keeps the caller's XDG directories, so it finds the same ASDF configuration (under
# XDG_CONFIG_HOME) as it would without this script.
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

# The script runs twice: once as called, and once inside the private bus, recognised by the
# first argument below. An environment variable would not do, because one a developer exported
# would make the first run skip dbus-run-session and start the daemon on their own bus.
inside=--inside-private-bus-started-by-with-secret-service
if [ "${1:-}" != "$inside" ]; then
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
  env -u GNOME_KEYRING_CONTROL dbus-run-session -- "$0" "$inside" "$dir" "$@" || status=$?
  exit "$status"
fi
dir=$2
shift 2

# Inside the private session. --unlock reads the password from standard input until it ends, and
# with no login keyring yet it creates one with that password and makes it the default.
# Only the daemon gets the temporary XDG directories; COMMAND reaches it over the private bus.
unset GNOME_KEYRING_CONTROL
head -c 32 /dev/urandom | base64 | tr -d '\n' \
  | XDG_RUNTIME_DIR="$dir/runtime" XDG_DATA_HOME="$dir/data" XDG_CONFIG_HOME="$dir/config" \
    gnome-keyring-daemon --unlock --components=secrets >/dev/null
exec "$@"
