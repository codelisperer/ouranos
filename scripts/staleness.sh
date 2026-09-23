#!/usr/bin/env sh
# staleness.sh --- say, in one line, how far behind this checkout is (#391).
#
#   scripts/staleness.sh          print the line
#   . scripts/staleness.sh        define staleness_line, print nothing
#
# WHY THIS EXISTS. The hub/main checkout is nobody's working tree by design (AGENTS.md,
# "One agent, one working tree"), so nothing routinely moves it -- and then it gets READ,
# to answer "what does the tree say now". The file reads perfectly. It is just an old file.
# On 2026-09-18 that cost two machines in one day: a lane stated five wrong values from a
# checkout 8 behind (a container image, a renamed test system, a README total), and the hub
# ran a pre-publication check from one 16 behind, got a FAIL naming a scaffold that had
# already been deleted, and was one step from filing a regression that never happened.
# The hub checkout measured 97 behind when this was written.
#
# IT PRINTS ON EVERY RUN, INCLUDING WHEN THE CHECKOUT IS CURRENT, and that is the whole
# design rather than a detail. A banner that appears only on bad news teaches readers that
# its absence means nothing happened -- and absence here is ambiguous between "this
# checkout is current" and "this call site never had the banner wired". A line that is
# always present makes its absence meaningful and its content ambient, which is the only
# property that helps someone who was not already suspicious. Same argument as
# verify-tree's NOT COVERED block (#385), applied to the proposal that came after it.
#
# IT NEVER FETCHES, deliberately. A network call here would make a fast local command
# depend on GitHub being up, and could hang. `origin/main' is a local ref and FETCH_HEAD's
# mtime is a local stat, so an honest "last fetch: 6h ago" beside a possibly-stale ref is
# nearly all of the value at none of the risk. The cost of everything below, measured:
# 0.00 s.
#
# WHAT IT DOES NOT SOLVE, said here so nobody rediscovers it: it does not fire on a bare
# `cat'. That is how all five of the lane's incidents actually happened. This narrows the
# window by making the state ambient; it does not close it.

staleness_line() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "not a git checkout"
    return 0
  fi

  # The branch's own upstream where it has one, origin/main otherwise. A lane on
  # work/<track> wants to hear about ITS upstream, not about main, or the line is noise it
  # learns to skip -- and a line people skip is worth less than no line.
  _up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  [ -n "$_up" ] || _up=origin/main
  if ! git rev-parse --verify --quiet "$_up" >/dev/null 2>&1; then
    echo "no upstream ref ($_up) -- cannot say whether this checkout is current"
    return 0
  fi

  _here=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  _behind=$(git rev-list --count "HEAD..$_up" 2>/dev/null || echo "?")
  _ahead=$(git rev-list --count "$_up..HEAD" 2>/dev/null || echo "?")

  # Fetch age from FETCH_HEAD's mtime. `git log -1 --format=%cr' would report the COMMIT's
  # age, which is a different fact: a ref fetched a minute ago can point at a week-old
  # commit, and reporting that as "fetched a week ago" would be false in the direction that
  # makes people trust a stale checkout.
  # TWO candidate paths, and the NEWER wins. FETCH_HEAD is per-worktree, but the refs a
  # fetch updates are shared across every worktree of the clone -- so a worktree that has
  # never fetched still has current `origin/main' the moment any sibling fetches. Reading
  # only the per-worktree path reported "never in this clone" in every worktree while the
  # refs were seconds old, which is false in the direction that makes a true line look like
  # noise, and a line people learn to skip is worth less than no line at all.
  _now=$(date +%s)
  _then=0
  for _cand in "$(git rev-parse --git-path FETCH_HEAD 2>/dev/null)" \
               "$(git rev-parse --git-common-dir 2>/dev/null)/FETCH_HEAD"; do
    [ -n "$_cand" ] && [ -f "$_cand" ] || continue
    _t=$(date -r "$_cand" +%s 2>/dev/null || stat -c %Y "$_cand" 2>/dev/null || echo 0)
    # `if', not `[ ] && x=y': under the `set -e' that board.sh runs with, a trailing test
    # that is simply FALSE makes the loop body return non-zero and can abort the CALLER.
    # A staleness banner that kills the command it was added to would be a poor trade.
    if [ "$_t" -gt "$_then" ]; then _then=$_t; fi
  done
  if [ "$_then" -gt 0 ]; then
    _age=$(( _now - _then ))
    if   [ "$_age" -lt 120 ];   then _fetched="just now"
    elif [ "$_age" -lt 7200 ];  then _fetched="$(( _age / 60 ))m ago"
    elif [ "$_age" -lt 172800 ];then _fetched="$(( _age / 3600 ))h ago"
    else                             _fetched="$(( _age / 86400 ))d ago"
    fi
  else
    _fetched="never in this clone"
  fi

  # AHEAD is a different fact from BEHIND and is never folded into "current". A branch one
  # commit ahead of main is missing nothing from upstream, but printing that as "current
  # with origin/main" invites the reader to hear "identical to main" -- which is how a
  # figure measured on a feature branch gets quoted as main's. Worded to match
  # verify-tree.lisp's `checkout:' line exactly: the two are deliberately separate
  # implementations (the gate assumes no shell on Windows), so the wording is the one thing
  # that can silently drift between them.
  if [ "$_behind" = "0" ] && [ "$_ahead" = "0" ]; then
    echo "$_here is current with $_up (fetched $_fetched)"
  elif [ "$_behind" = "0" ]; then
    echo "$_here: nothing missing from $_up, and $_ahead commit(s) ahead of it (fetched $_fetched)"
  else
    printf '%s is %s commit(s) BEHIND %s (fetched %s) -- files here are NOT what the tree says now; read `git show %s:<path>`\n' \
      "$_here" "$_behind" "$_up" "$_fetched" "$_up"
  fi
}

# Sourced (`. scripts/staleness.sh') defines the function and prints nothing; executed,
# it prints. $0 ends in this script's name only in the executed case.
case "$0" in
  *staleness.sh) staleness_line ;;
esac
