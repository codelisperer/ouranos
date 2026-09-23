#!/usr/bin/env sh
# board.sh --- read the coordination board.
#
#   scripts/board.sh                  every open item, grouped by agent
#   scripts/board.sh "Linux/WSL"      one agent's queue
#   scripts/board.sh mine             this machine's queue (see scripts/agent.sh)
#   scripts/board.sh unassigned       the pool -- what you may take
#
# The board (https://github.com/orgs/codelisperer/projects/1) is the shared state between
# the several assistants working this tree from different machines, so that "who is doing
# what" is a query rather than a question somebody has to be asked. See AGENTS.md,
# "The board".
#
# Why a script rather than the raw command in the docs: `gh project item-list` prints
# neither Status nor Agent in its table form and a wall of JSON otherwise, so the useful
# invocation is long enough that nobody would type it twice. Parsing uses gh's OWN
# embedded jq -- no python, no jq install -- because this has to work identically in
# git-bash on Windows.

set -eu

PROJECT=1
OWNER=codelisperer
WANT="${1:-}"

# How stale is the checkout this is being run from (pre-publication issue 391)? Printed BEFORE the gh check, so
# a machine without gh still learns it, and before any board output, because the hub loop's
# step 1 is "read the whole board before touching anything" -- which makes this the one
# command guaranteed to run at the start of a pass.
#
# Anchored to the directory THIS SCRIPT lives in, not to $PWD: `scripts/board.sh' invoked
# by absolute path from inside some other repository would otherwise report that
# repository's staleness under this one's name, which is worse than printing nothing.
#
# Subshell, so the `cd' cannot leak into the rest of the script.
(
  cd "$(dirname "$0")" 2>/dev/null || exit 0
  . ./staleness.sh
  echo "board: $(staleness_line)"
)

command -v gh >/dev/null 2>&1 || { echo "board: gh is not installed" >&2; exit 2; }

# The project scope is separate from `repo` and is NOT granted by default. Without it
# this fails with a 403 that does not mention scopes, so say so plainly.
#
# READ-ONLY, so `read:project` is enough -- and it has to be accepted explicitly, because
# the substring `'project'` does not match `'read:project'`. Demanding the write scope for
# a query is how you teach people to over-grant a token.
case "$(gh auth status 2>&1 || true)" in
  *"'project'"*|*"'read:project'"*) ;;
  *) echo "board: your gh token lacks project scope." >&2
     echo "board: run  gh auth refresh -s read:project  (or -s project to WRITE)." >&2
     exit 2 ;;
esac

# `mine` resolves this checkout's identity rather than making the caller retype it --
# and, more to the point, rather than making an assistant GUESS which machine it is.
# scripts/agent.sh fails loudly when it does not know, so `mine` cannot quietly return
# somebody else's queue.
if [ "$WANT" = "mine" ]; then
  WANT="$(sh "$(dirname "$0")/agent.sh")" || exit $?
  echo "board: $WANT"
fi

if [ -n "$WANT" ]; then
  gh project item-list "$PROJECT" --owner "$OWNER" --limit 300 --format json --jq \
    "[.items[] | select(.status != \"Done\") | select((.agent // \"unassigned\") == \"$WANT\")]
     | if length == 0 then \"  (nothing open for $WANT)\"
       else sort_by(.priority // \"zz\")[] | \"  \((.priority // \"--    \")[0:2])  #\(.content.number // \"-\")  \(.status // \"-\")  \(.content.title // .title | .[0:60])\"
       end"
  exit 0
fi

gh project item-list "$PROJECT" --owner "$OWNER" --limit 300 --format json --jq '
  [.items[] | select(.status != "Done")]
  | group_by(.agent // "unassigned")
  | .[]
  | ("\n" + (.[0].agent // "unassigned")),
    (sort_by(.priority // "zz")[] | "  \((.priority // "--    ")[0:2])  #\(.content.number // "-")  \(.status // "-")  \(.content.title // .title | .[0:60])")'
