#!/usr/bin/env bash
# ci-suite-baseline.sh --- download the same platform's suite status from an earlier run on main (#199)
#
#     GH_TOKEN=... GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=... [BASE_SHA=<sha>] \
#       scripts/ci-suite-baseline.sh <artifact-name> <out-file>
#
# Writes OUT-FILE, which scripts/suite-status.lisp's `diff' mode reads as the baseline. It is
# either the suite-status file of an earlier run, or one line beginning `unavailable:' that says
# why none could be read: the API refused (for example, the token lacks `actions: read'), no run
# had the artifact (they are kept 30 days), or gh is missing.
#
# THE BASELINE is the newest completed `push' run of verify.yml on main that has ARTIFACT-NAME
# and whose gate finished. Main's runs are not cancelled since #197. With BASE_SHA (a pull
# request's base commit), a run of that commit is tried first; when there is none, the latest
# run is used and the file says so on a `baseline-note:' line, which the diff prints.
#
# It never fails the job: every failure ends in an `unavailable:' line and exit 0.

set -u

NAME="${1:?usage: ci-suite-baseline.sh <artifact-name> <out-file>}"
OUT="${2:?usage: ci-suite-baseline.sh <artifact-name> <out-file>}"
WORK=$(mktemp -d)
ERR="$WORK/err"

unavailable() {
  echo "unavailable: $*" > "$OUT"
  echo "ci-suite-baseline: $*" >&2
  exit 0
}

command -v gh >/dev/null 2>&1 || unavailable "gh is not installed on this runner"
[ -n "${GITHUB_REPOSITORY:-}" ] || unavailable "GITHUB_REPOSITORY is not set"

RUNS="repos/${GITHUB_REPOSITORY}/actions/workflows/verify.yml/runs?branch=main&event=push&status=completed&per_page=10"

# The runs to try, in order: the base commit's first, then the newest.
base_ids=""
if [ -n "${BASE_SHA:-}" ]; then
  base_ids=$(gh api "${RUNS}&head_sha=${BASE_SHA}" --jq '.workflow_runs[].id' 2>"$ERR") ||
    unavailable "listing main's runs failed: $(head -1 "$ERR")"
fi
latest_ids=$(gh api "$RUNS" --jq '.workflow_runs[].id' 2>"$ERR") ||
  unavailable "listing main's runs failed: $(head -1 "$ERR")"

tried=0
for id in $base_ids $latest_ids; do
  [ "$id" = "${GITHUB_RUN_ID:-}" ] && continue
  # Five downloads at most, so a long stretch of runs without the artifact costs a few calls.
  [ "$tried" -ge 5 ] && break
  tried=$((tried + 1))
  dir="$WORK/$id"
  if gh run download "$id" -R "$GITHUB_REPOSITORY" -n "$NAME" -D "$dir" >/dev/null 2>"$ERR" &&
     [ -f "$dir/suite-status.txt" ] &&
     ! grep -q '^gate: unfinished' "$dir/suite-status.txt"; then
    cp "$dir/suite-status.txt" "$OUT"
    if [ -n "${BASE_SHA:-}" ] && ! printf '%s\n' $base_ids | grep -qx "$id"; then
      echo "baseline-note: no run on main of this pull request's base commit ${BASE_SHA} had a usable status, so this is the newest one that did." >> "$OUT"
    fi
    echo "ci-suite-baseline: using run $id"
    exit 0
  fi
  if [ -f "$dir/suite-status.txt" ]; then
    echo "ci-suite-baseline: run $id's gate did not finish, so the next run is tried" >&2
  else
    echo "ci-suite-baseline: run $id has no usable $NAME: $(head -1 "$ERR" 2>/dev/null)" >&2
  fi
done

unavailable "none of the ${tried} newest completed push runs of verify.yml on main had a usable artifact ${NAME}"
