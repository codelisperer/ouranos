#!/usr/bin/env sh
# ticket.sh --- what is pre-publication issue 165, again?
#
#   scripts/ticket.sh 165              one ticket
#   scripts/ticket.sh 165 166 122      several
#   scripts/ticket.sh 165 --body       the full body too
#
# A bare issue number is unreadable in a conversation, a commit message or a board row —
# everyone ends up opening a browser tab to remember what "pre-publication issue 165" was. This turns a number
# back into a sentence, offline of the browser.
#
# POSIX sh + gh only, same constraint as board.sh: this has to work in git-bash on Windows.

set -eu

REPO=codelisperer/ouranos
BODY=no
NUMS=""

for a in "$@"; do
  case "$a" in
    --body|-b) BODY=yes ;;
    -h|--help) echo "usage: scripts/ticket.sh <number>... [--body]" >&2; exit 2 ;;
    *[!0-9]*)  echo "ticket: '$a' is not an issue number" >&2; exit 2 ;;
    *)         NUMS="$NUMS $a" ;;
  esac
done
[ -n "$NUMS" ] || { echo "usage: scripts/ticket.sh <number>... [--body]" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "ticket: gh is not installed" >&2; exit 2; }

for n in $NUMS; do
  # `gh issue view` resolves pull requests too, so a PR number works here as well.
  if [ "$BODY" = yes ]; then
    gh issue view "$n" --repo "$REPO" \
      --json number,state,title,labels,body \
      --jq '"#\(.number)  [\(.state)]  \(.title)\n\([.labels[].name] | join(", "))\n\n\(.body)"' \
      2>/dev/null || echo "#$n  (not found)"
    echo
  else
    gh issue view "$n" --repo "$REPO" --json number,state,title \
      --jq '"#\(.number)  [\(.state)]  \(.title)"' \
      2>/dev/null || echo "#$n  (not found)"
  fi
done
