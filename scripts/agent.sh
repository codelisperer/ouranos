#!/usr/bin/env sh
# agent.sh --- which agent is this machine?
#
#   scripts/agent.sh                  print this machine's board identity
#   scripts/agent.sh --set "Windows"  record it for this checkout
#   scripts/agent.sh --list           the identities the board accepts
#
# AGENTS.md requires every AI-managed ticket to state its instance, and the board's
# `Agent` field is one of a fixed set. Both were previously answerable only by asking the
# maintainer -- which is exactly the human relay the board exists to remove. An assistant
# that cannot name itself cannot claim work without guessing, and a wrong guess takes an
# item out of another machine's queue.
#
# Resolution order, first hit wins:
#
#   1. $OURANOS_AGENT          -- explicit; right for CI, a container, or a shell profile
#   2. .ouranos-agent          -- a one-line file at the repo root, gitignored
#   3. nothing                 -- fail loudly with the fix, never guess
#
# Deliberately NOT derived from hostname. A hostname table would be a committed file that
# has to be edited on every new machine, would put machine names in a repo that has a
# confidentiality rule about naming things, and would silently mislabel a clone rather
# than admit it does not know. Refusing to answer is better than answering wrongly: the
# failure mode of a bad identity is stealing another agent's work.
#
# POSIX sh, no jq, no python -- same constraint as board.sh, which has to run in git-bash.

set -eu

# The board's Agent field. Keep in step with the single-select options on
# https://github.com/orgs/codelisperer/projects/1 and with AGENTS.md.
VALID='PM
Mac (home)
Mac (work)
Windows
Linux/WSL
App
unassigned'

root() {
  # The repo root, without assuming the caller's working directory.
  git rev-parse --show-toplevel 2>/dev/null || {
    echo "agent: not inside a git checkout" >&2; exit 2; }
}

valid_p() {
  printf '%s\n' "$VALID" | grep -Fqx "$1"
}

usage() {
  echo "usage: scripts/agent.sh [--set NAME | --list]" >&2
  exit 2
}

case "${1:-}" in
  --list) printf '%s\n' "$VALID"; exit 0 ;;
  --set)
    [ $# -eq 2 ] || usage
    if ! valid_p "$2"; then
      echo "agent: \"$2\" is not a board identity. Valid:" >&2
      printf '%s\n' "$VALID" | sed 's/^/  /' >&2
      exit 2
    fi
    printf '%s\n' "$2" > "$(root)/.ouranos-agent"
    echo "agent: this checkout is \"$2\"  (.ouranos-agent, gitignored)"
    exit 0 ;;
  '') ;;
  *) usage ;;
esac

# 1. the environment wins
if [ -n "${OURANOS_AGENT:-}" ]; then
  if valid_p "$OURANOS_AGENT"; then printf '%s\n' "$OURANOS_AGENT"; exit 0; fi
  echo "agent: \$OURANOS_AGENT is \"$OURANOS_AGENT\", which is not a board identity." >&2
  exit 2
fi

# 2. the checkout-local file
FILE="$(root)/.ouranos-agent"
if [ -f "$FILE" ]; then
  # strip a trailing newline and any stray CR from a Windows editor
  NAME="$(tr -d '\r\n' < "$FILE")"
  if valid_p "$NAME"; then printf '%s\n' "$NAME"; exit 0; fi
  echo "agent: $FILE says \"$NAME\", which is not a board identity." >&2
  exit 2
fi

# 3. refuse to guess
echo "agent: this machine has no board identity." >&2
echo "agent: set one with   scripts/agent.sh --set \"Mac (work)\"" >&2
echo "agent: or export OURANOS_AGENT. Valid identities:" >&2
printf '%s\n' "$VALID" | sed 's/^/  /' >&2
exit 1
