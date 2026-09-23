#!/usr/bin/env sh
# test-postgres.sh --- the Postgres the verification gate needs (pre-publication issue 176).
#
#   scripts/test-postgres.sh up      start it and wait until it actually answers
#   scripts/test-postgres.sh down    stop and remove it
#   scripts/test-postgres.sh url     print the URL to export, and nothing else
#   scripts/test-postgres.sh env     print the full `export ...` line, for eval
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

CONTAINER=ouranos-test-pg
URL='postgres://ouranos:ouranos@127.0.0.1:55432/ouranos_test?sslmode=disable'

root() { CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd; }
COMPOSE_FILE="$(root)/docker-compose.test.yml"

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

case "${1:-}" in
  up)
    command -v docker >/dev/null 2>&1 || {
      echo "test-postgres: docker is not installed or not on PATH." >&2; exit 2; }
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
      printf 'test-postgres: eval "$(scripts/test-postgres.sh env)"\n'
      exit 0
    fi
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
  *)
    echo "usage: scripts/test-postgres.sh up|down|url|env" >&2
    exit 2
    ;;
esac
