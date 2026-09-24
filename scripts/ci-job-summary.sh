#!/usr/bin/env bash
# ci-job-summary.sh --- write which step failed, and which suites, into the job summary (#167)
#
#     STEPS_JSON='${{ toJSON(steps) }}' scripts/ci-job-summary.sh <title> [verify.log] [readme.log]
#
# A job's conclusion is one bit. It cannot distinguish two failing suites from three, so a
# leg that is already red absorbs a new failure without anything changing where a reader
# looks. Until this script, finding out which suites failed meant opening the job log, or
# fetching it through the API. This writes it to $GITHUB_STEP_SUMMARY, which GitHub shows
# on the run's page and on the pull request's checks, on every leg and on success too, so a
# reader can compare two runs without opening either log.
#
# What it reports:
#   * every step whose outcome was not success or skipped, by its `id' (the steps context
#     has no names, so every step in verify.yml carries an id for this);
#   * the gate's per-suite FAIL lines and its `VERDICT: FAIL' reasons, from the log the
#     gate step tees;
#   * the gate's total and verdict, and the README check's verdict where that step ran.
#
# What it does NOT do: compare against a previous run. #167 also proposes a stored
# baseline of failing suites per platform, with the difference reported. How that baseline
# is stored and what a growing set should do are open questions on the issue, so that part
# is not here.
#
# It never fails the job. A summary that cannot be written is a missing summary, not a
# reason to turn a green leg red, so every failure here is reported and ignored.

set -u

TITLE="${1:-verify}"
LOG="${2:-verify.log}"
README_LOG="${3:-readme.log}"
OUT="${GITHUB_STEP_SUMMARY:-}"
BODY=$(mktemp)

{
  echo "### ${TITLE}"
  echo

  # --- steps ------------------------------------------------------------------
  if [ -n "${STEPS_JSON:-}" ] && command -v jq >/dev/null 2>&1; then
    bad=$(printf '%s' "$STEPS_JSON" |
            jq -r 'to_entries[] | select(.value.outcome != "success" and .value.outcome != "skipped")
                   | "| `\(.key)` | \(.value.outcome) |"' 2>/dev/null)
    if [ -n "$bad" ]; then
      echo "**Steps that did not succeed:**"
      echo
      echo "| step | outcome |"
      echo "|---|---|"
      echo "$bad"
    else
      echo "Every step succeeded or was skipped."
    fi
  else
    echo "Step outcomes unavailable (no STEPS_JSON, or no jq on this runner)."
  fi
  echo

  # --- the gate -----------------------------------------------------------------
  if [ -f "$LOG" ]; then
    # Carriage returns come from the Windows leg; strip them so the patterns match there.
    total=$(tr -d '\r' < "$LOG" | grep -E '^total checks executed:' | tail -1)
    verdict=$(tr -d '\r' < "$LOG" | grep -E '^VERDICT: (PASS|FAIL)' | tail -1)
    echo "**Gate:** ${verdict:-no verdict line (the gate did not finish)}. ${total:-No total line.}"
    echo
    suites=$(tr -d '\r' < "$LOG" | grep -E '^  FAIL {4}')
    if [ -n "$suites" ]; then
      echo "**Failing suites** ($(printf '%s\n' "$suites" | wc -l | tr -d ' ')):"
      echo
      echo '```'
      printf '%s\n' "$suites"
      echo '```'
      echo
    fi
    # The reasons under `VERDICT: FAIL' cover what the suite lines do not: a system that
    # failed to compile, a suite that never ran, a zero check count.
    reasons=$(tr -d '\r' < "$LOG" | sed -n '/^VERDICT: FAIL/,$p' | grep -E '^  - ')
    if [ -n "$reasons" ]; then
      echo "**Why the gate failed:**"
      echo
      echo '```'
      printf '%s\n' "$reasons"
      echo '```'
      echo
    fi
  else
    echo "**Gate:** no log at \`${LOG}\` (the gate step did not run, or failed before writing it)."
    echo
  fi

  # --- the README counts (Linux leg only) --------------------------------------
  if [ -f "$README_LOG" ]; then
    rv=$(tr -d '\r' < "$README_LOG" | grep -E '^VERDICT:' | tail -1)
    echo "**README counts:** ${rv:-no verdict line}"
    drift=$(tr -d '\r' < "$README_LOG" | grep -E '<-- DRIFT')
    if [ -n "$drift" ]; then
      echo
      echo '```'
      printf '%s\n' "$drift"
      echo '```'
    fi
    echo
  fi
} > "$BODY"

# Printed to the step's log as well. The summary page has no API to read it back, so the
# log is where a script, or a reader without the page, can check what was reported.
cat "$BODY"
if [ -n "$OUT" ]; then
  cat "$BODY" >> "$OUT" 2>/dev/null || echo "ci-job-summary: could not write the summary to $OUT" >&2
fi
rm -f "$BODY"

exit 0
