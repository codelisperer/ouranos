#!/usr/bin/env sh
# pr-runs.sh --- list each open pull request's head and the verify run for that head (#1025).
#
#   scripts/pr-runs.sh        every open pull request; exits 1 when any head has no verify run
#
# A pull request that conflicts with main gets no pull_request run, because GitHub cannot make
# refs/pull/N/merge for it, so a push to it is never tested and the checks it still shows belong
# to an earlier head. This script reads each open pull request's head and asks for verify runs
# on exactly that commit. A head with none is printed as NO RUN, with what to do about it; see
# AGENTS.md, "A push to a pull request that conflicts with main gets no CI run".
#
# A head pushed in the last minute or two may have no run yet because GitHub has not queued it.
# Run the script again before acting on a NO RUN for a head that was just pushed.
#
# Parsing uses gh's own embedded jq (--jq), as scripts/board.sh does, so nothing else needs
# installing.

set -eu

REPO=codelisperer/ouranos
WORKFLOW=verify.yml

if ! command -v gh >/dev/null 2>&1; then
  echo "pr-runs: gh is not installed; see https://cli.github.com" >&2
  exit 2
fi

# One line per open pull request: number, head commit, branch, and whether GitHub can merge it.
prs=$(gh pr list --repo "$REPO" --state open --limit 200 \
        --json number,headRefOid,headRefName,mergeable \
        --jq '.[] | "\(.number) \(.headRefOid) \(.headRefName) \(.mergeable)"')

missing=""
printf '%-6s %-9s %-12s %s\n' PR HEAD MERGEABLE "VERIFY RUN FOR THIS HEAD"
# A here-document rather than a pipe, so the loop runs in this shell and MISSING survives it.
while read -r number sha branch mergeable; do
  [ -n "$number" ] || continue
  run=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --commit "$sha" --limit 1 \
          --json databaseId,status,conclusion \
          --jq '.[0] // empty | [.databaseId, .status, .conclusion] | map(tostring)
                | map(select(. != "")) | join(" ")')
  short=$(echo "$sha" | cut -c1-8)
  if [ -n "$run" ]; then
    printf '%-6s %-9s %-12s %s\n' "#$number" "$short" "$mergeable" "$run"
  else
    printf '%-6s %-9s %-12s %s\n' "#$number" "$short" "$mergeable" "NO RUN"
    if [ "$mergeable" = CONFLICTING ]; then
      echo "       it conflicts with main: merge main, or gh workflow run $WORKFLOW --ref $branch"
    fi
    missing="$missing #$number"
  fi
done <<PRS
$prs
PRS

if [ -n "$missing" ]; then
  echo "pr-runs: no verify run for the head of:$missing"
  exit 1
fi
echo "pr-runs: every open pull request's head has a verify run"
