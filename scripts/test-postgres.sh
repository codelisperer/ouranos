#!/usr/bin/env sh
# test-postgres.sh --- the Postgres the verification gate needs (pre-publication issue 176).
#
#   scripts/test-postgres.sh up      pull a missing image, start it, and wait until it answers
#   scripts/test-postgres.sh down    stop and remove it
#   scripts/test-postgres.sh url     print the URL to export, and nothing else
#   scripts/test-postgres.sh env     print the full `export ...` line, for eval
#   scripts/test-postgres.sh check   say whether the running container is the declared image;
#                                    exit 0 if it is, 1 if not, 2 if none is running
#
# Typical use:
#
#   scripts/test-postgres.sh up
#   eval "$(scripts/test-postgres.sh env)"
#   sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
#
# This is a CONVENIENCE, not a dependency. The suite's contract is the
# MNEMOSYNE_TEST_PG_URL environment variable (see mnemosyne/tests/backends.lisp); a
# container is one way to satisfy it and a server you already run is another. Nothing in
# the tree loads, links, or shells out to Docker -- deleting this script would cost
# convenience and no correctness.
#
# POSIX sh, no jq, no python -- same constraint as board.sh and agent.sh, which have to run
# in git-bash on Windows.

set -eu

URL='postgres://ouranos:ouranos@127.0.0.1:55432/ouranos_test?sslmode=disable'

root() { CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd; }
# The two OURANOS_TEST_PG_* overrides exist so the image check below can be measured against a
# scratch container without touching the one other worktrees may be using. Unset, they are the
# container and compose file this repository declares.
CONTAINER="${OURANOS_TEST_PG_CONTAINER:-ouranos-test-pg}"
COMPOSE_FILE="${OURANOS_TEST_PG_COMPOSE:-$(root)/docker-compose.test.yml}"

# IS THE RUNNING CONTAINER THE ONE THE COMPOSE FILE DECLARES? (#147) `docker compose up` starts
# an existing container as it is, so after `image:` changes in the compose file, anyone whose
# container predates the change keeps the old image with no warning. That happened when the image
# became pgvector: the vector suites then skipped, correctly and by name, and coverage dropped
# with nothing going red. This compares the two and says which, every time.
declared_image() {
  awk '/^[[:space:]]*image:[[:space:]]*/ { print $2; exit }' "$COMPOSE_FILE"
}
running_image() {
  docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true
}
# Prints one line when they match. Prints a block on stderr and returns 1 when they do not.
image_report() {
  want="$(declared_image)"
  have="$(running_image)"
  if [ "$have" = "$want" ]; then
    echo "test-postgres: $CONTAINER runs $have, as $(basename "$COMPOSE_FILE") declares."
    return 0
  fi
  {
    echo ""
    echo "test-postgres: MISMATCH. $CONTAINER runs '$have',"
    echo "test-postgres: but $(basename "$COMPOSE_FILE") declares '$want'."
    echo "test-postgres: The container predates a change to the compose file, and \`up\` does not"
    echo "test-postgres: recreate it, so tests run against a server the repository no longer describes"
    echo "test-postgres: (after the pgvector change, the vector suites skipped on every run)."
    echo "test-postgres: To recreate it -- which stops it for any other worktree using it:"
    echo "test-postgres:   scripts/test-postgres.sh down && scripts/test-postgres.sh up"
    echo ""
  } >&2
  return 1
}

compose() {
  # `docker compose` (v2 plugin) with a fallback to the standalone v1 binary, because both
  # are still in the wild and the difference is not the caller's problem.
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    echo "test-postgres: no 'docker compose' or 'docker-compose' found." >&2
    echo "test-postgres: this script is optional -- point MNEMOSYNE_TEST_PG_URL at any" >&2
    echo "test-postgres: Postgres you can reach and the suite will use it." >&2
    exit 2
  fi
}

# PULL A MISSING IMAGE BEFORE STARTING THE CONTAINER, AND TRY MORE THAN ONCE (#245). `compose up`
# pulls a missing image itself, and when the registry refuses that pull, `compose up` fails at
# once. On one pull request's CI run, Docker Hub refused the pull of this public image with
# "unauthorized: authentication required". The Linux leg failed before the gate ran, and
# re-running the job at the same commit passed. This function therefore pulls a missing image
# first, up to four times, with pauses of 10, 20 and 30 seconds between the tries. `compose up`
# then finds the image present and does not pull it again.
#
# When every try fails, the last line names the image and the number of tries, and says that this
# is a registry failure and not a test result. On GitHub Actions the same line is appended to
# $GITHUB_STEP_SUMMARY, because the rest of the job summary, which scripts/ci-job-summary.sh
# writes, shows only that this step failed.
#
# The compose file is checked first, with `compose config -q`. An invalid file makes every pull
# fail as well, and without this check it would be retried four times and then reported as a
# registry failure. Instead, compose's own error is printed and the script exits 2.
#
# When a copy of the image is already on this machine, nothing is pulled, which is also what
# `compose up` does by default. Pulling would move the local tag to whatever build the registry
# has now, and so change a developer's database without their asking. CI's runners start without
# a copy, so on CI the image is always pulled, with the retries above.
pull_image() {
  compose config -q || {
    echo "test-postgres: compose rejected $COMPOSE_FILE (its error is above), so nothing was pulled." >&2
    exit 2
  }
  image="$(declared_image)"
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "test-postgres: $image is already on this machine, so it is not pulled."
    return 0
  fi
  try=1
  for pause in 10 20 30; do
    compose pull && return 0
    echo "test-postgres: pulling $image failed on try $try; trying again in ${pause}s." >&2
    sleep "$pause"
    try=$((try + 1))
  done
  compose pull && return 0
  msg="test-postgres: could not pull $image after $try tries. This is a registry failure, not a test result."
  echo "$msg" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$msg" >> "$GITHUB_STEP_SUMMARY" ||
      echo "test-postgres: could not write that line to $GITHUB_STEP_SUMMARY." >&2
  fi
  exit 1
}

case "${1:-}" in
  up)
    command -v docker >/dev/null 2>&1 || {
      echo "test-postgres: docker is not installed or not on PATH." >&2; exit 2; }
    # The daemon has to answer too. When it does not, every pull in pull_image fails, and the line
    # printed after the last try would blame the registry for a daemon that is not running.
    docker version >/dev/null 2>&1 || {
      echo "test-postgres: docker is installed, but its daemon is not answering." >&2; exit 2; }
    # ALREADY RUNNING IS SUCCESS, and this is not merely politeness. The container name is
    # fixed while compose derives its PROJECT name from the containing DIRECTORY -- so the
    # very setup AGENTS.md mandates, one worktree per agent, makes `up` in the second
    # worktree collide with the healthy container the first one started:
    #
    #   Conflict. The container name "/ouranos-test-pg" is already in use
    #
    # Failing there is wrong twice over: the caller's precondition (a Postgres answering on
    # 55432) is already satisfied, and the obvious reading of the error -- that something is
    # broken -- sends you to remove a container another agent's run is using.
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)" = healthy ]; then
      echo "test-postgres: $CONTAINER is already running and healthy."
      # Reported, not refused: the container may be serving another worktree's run, and
      # recreating it from here would pull the database out from under that run.
      image_report || true
      printf 'test-postgres: eval "$(scripts/test-postgres.sh env)"\n'
      exit 0
    fi
    pull_image
    compose up -d
    # Wait for the HEALTHCHECK, not for the container to exist. `up -d` returns as soon as
    # the process starts, and Postgres refuses connections for a second or two after that
    # -- so a suite launched immediately fails with a connection error that looks exactly
    # like a misconfigured URL. Waiting here is what keeps that from being debugged twice.
    printf 'test-postgres: waiting for %s to answer' "$CONTAINER"
    i=0
    while [ "$i" -lt 60 ]; do
      state="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)"
      if [ "$state" = healthy ]; then
        printf '\ntest-postgres: ready.\n'
        image_report || true
        printf 'test-postgres: eval "$(scripts/test-postgres.sh env)"\n'
        exit 0
      fi
      printf '.'
      i=$((i + 1))
      sleep 1
    done
    printf '\n'
    echo "test-postgres: $CONTAINER did not become healthy in 60s." >&2
    echo "test-postgres: last state: ${state:-unknown}" >&2
    compose logs --tail 20 >&2 || true
    exit 1
    ;;
  down)
    compose down -v
    ;;
  url)
    echo "$URL"
    ;;
  env)
    echo "export MNEMOSYNE_TEST_PG_URL='$URL'"
    ;;
  check)
    if [ -z "$(running_image)" ]; then
      echo "test-postgres: $CONTAINER is not running." >&2
      exit 2
    fi
    image_report
    ;;
  *)
    echo "usage: scripts/test-postgres.sh up|down|url|env|check" >&2
    exit 2
    ;;
esac
