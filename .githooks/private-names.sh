# private-names.sh --- the private-name check that commit-msg, pre-commit and pre-push share.
# Sourced by those hooks, never run on its own.
#
# WHAT IT KEEPS OUT. Client and product names that must never appear in this repository
# (AGENTS.md, "Tasks, identity, confidentiality"). While the repository was private, one scan
# at publication time was enough: scripts/publish-public.sh read the list and refused to build
# a tree that contained a name. Development now happens in the public repository, so a commit
# message, an added line, a file path or a branch name is public as soon as it is pushed. The
# check therefore has to run on every commit and every push.
#
# WHERE THE LIST COMES FROM, in this order:
#
#   1. The file named by `git config ouranos.privateNames`. The maintainer sets this once per
#      machine with --global, and it then covers every clone and worktree on that machine.
#      Setting it is also what makes the check fail closed: if the named file is missing or
#      empty, every commit and push is refused. Otherwise a machine whose list went missing
#      would pass everything, and nothing would show that the check had stopped running.
#   2. `.private-names` in the MAIN checkout, found through git's common directory. A linked
#      worktree has its own working tree and cannot see untracked files in the main one, and
#      lanes commit in worktrees, so looking only beside the current worktree would find
#      nothing and check nothing.
#   3. Neither exists: the hooks do nothing. That is the case for a contributor, who has no
#      list and no private names to leak.
#
# The list's format is the one publish-public.sh reads: one extended regular expression per
# line, matched case-insensitively anywhere in the text. Blank lines and lines starting with #
# are ignored, and so is trailing whitespace on a line, including Windows line endings.
#
# WHAT A REFUSAL PRINTS: where the match is -- a line of the message, a path and line number,
# a commit -- and never the matching text. Refusals get pasted into issues, pull requests and
# session logs, and a refusal that repeated the name would publish it in exactly the way the
# check exists to prevent. For the same reason a file path that contains a name is counted,
# not printed.
#
# WHAT IT DOES NOT COVER: pull-request titles and bodies, issue text and comments, which never
# pass through git on this machine; and text inside binary files.

# Print the refusal's first line.
pn_refuse_intro() {
  printf '\n  REFUSED: %s\n\n' "$1" >&2
}

# The advice every refusal ends with.
pn_advice() {
  cat >&2 <<'MSG'
  This refusal gives locations only, never the matching text, so it is safe to quote in an
  issue or a log.

  Replace the name with a neutral description, such as "a consuming app", and try again. The
  rule is in AGENTS.md, under "Tasks, identity, confidentiality".

  If the match is wrong, narrow that entry in the private-names list instead of bypassing the
  hook, because nothing records that a commit or a push bypassed it.

MSG
}

# Set PN_FILE and PN_PATTERN. Returns 0 with PN_PATTERN empty when no list applies here, and
# returns 1, after saying why, when a list was configured or found but cannot be used.
pn_load() {
  PN_PATTERN=
  PN_FILE=$(git config --type=path --get ouranos.privateNames 2>/dev/null || true)
  if [ -n "$PN_FILE" ]; then
    if [ ! -f "$PN_FILE" ]; then
      pn_refuse_intro "the private-names list this machine is configured to use does not exist."
      printf '  ouranos.privateNames is set to %s, and there is no file there.\n' "$PN_FILE" >&2
      printf '  Restore the file, or point the setting at where the list is now:\n\n' >&2
      printf '      git config --global ouranos.privateNames <path>\n\n' >&2
      return 1
    fi
  else
    pn_common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    [ -n "$pn_common" ] || return 0
    PN_FILE="$(dirname "$pn_common")/.private-names"
    if [ ! -f "$PN_FILE" ]; then
      PN_FILE=
      return 0
    fi
  fi
  # sed removes trailing whitespace from every line before anything else reads it, including
  # the carriage return a Windows editor saves at the end of each line. Left in place, either
  # one ends the entry with a character the text does not contain, and that entry matches
  # nothing without any error. Doing it first also makes a line holding only a CR blank.
  PN_PATTERN=$(sed 's/[[:space:]]*$//' "$PN_FILE" | grep -vE '^[[:space:]]*(#|$)' | paste -sd '|' -)
  if [ -z "$PN_PATTERN" ]; then
    pn_refuse_intro "the private-names list is empty, so the check could not fail."
    printf '  %s has no entries. Add them, or delete the file if this machine has no list.\n\n' "$PN_FILE" >&2
    return 1
  fi
  # grep exits 2 on a pattern it cannot parse. Such a list would match nothing, and every
  # commit would look clean.
  pn_status=0
  printf '\n' | grep -iE "$PN_PATTERN" >/dev/null 2>&1 || pn_status=$?
  if [ "$pn_status" -eq 2 ]; then
    pn_refuse_intro "the private-names list is not a valid extended regular expression."
    printf '  Check the entries in %s.\n\n' "$PN_FILE" >&2
    return 1
  fi
  return 0
}

# Read a unified diff made with -U0 and b/ destination prefixes on stdin, and print path:line
# for every ADDED line that contains a name. Only added lines count: a commit that removes a
# name is the fix, and refusing it would make the fix impossible to commit. $1 is a
# newline-separated list of paths to leave out, because those paths contain a name themselves
# and printing path:line for them would print the name.
pn_hits_in_diff() {
  PN_SKIP_PATHS=$1 awk '
    BEGIN { n = split(ENVIRON["PN_SKIP_PATHS"], s, "\n"); for (i = 1; i <= n; i++) skip[s[i]] = 1 }
    /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
    /^--- /    { next }
    /^@@ /     { if (match($0, /\+[0-9]+/)) line = substr($0, RSTART + 1, RLENGTH - 1) - 1; next }
    /^\+/      { line++; if (!(path in skip)) print path ":" line ":" substr($0, 2) }
  ' | grep -iE "$PN_PATTERN" | cut -d: -f1,2 || true
}

# Print the line numbers of a commit message that contain a name, comma-separated. Numbered as
# the message was written, and stopping at the scissors line below which `git commit -v` puts
# the diff, which is checked separately.
pn_hits_in_message() {
  awk '/^# -+ >8 -+$/ { exit } { print }' "$1" | grep -inE "$PN_PATTERN" | cut -d: -f1 | paste -sd, - || true
}

# commit-msg: check the message in file $1.
pn_check_message() {
  pn_load || return 1
  [ -n "$PN_PATTERN" ] || return 0
  pn_lines=$(pn_hits_in_message "$1")
  [ -n "$pn_lines" ] || return 0
  pn_refuse_intro "a private name appears in the commit message."
  printf '  Line %s of the message, counted as written.\n\n' "$pn_lines" >&2
  pn_advice
  return 1
}

# pre-commit: check what is staged -- added lines, and the paths of added, copied, modified or
# renamed files.
pn_check_staged() {
  pn_load || return 1
  [ -n "$PN_PATTERN" ] || return 0
  pn_paths=$(git diff --cached --name-only --diff-filter=ACMR | grep -iE "$PN_PATTERN" || true)
  pn_lines=$(git diff --cached --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -U0 --diff-filter=ACMR \
               | pn_hits_in_diff "$pn_paths")
  [ -z "$pn_paths" ] && [ -z "$pn_lines" ] && return 0
  pn_refuse_intro "a private name appears in what you are about to commit."
  if [ -n "$pn_paths" ]; then
    printf '  %s file path(s) being added or renamed contain one. List them with:\n\n' \
      "$(printf '%s\n' "$pn_paths" | wc -l | tr -d ' ')" >&2
    printf '      git diff --cached --name-only\n\n' >&2
  fi
  if [ -n "$pn_lines" ]; then
    printf '  Added lines that contain one:\n\n' >&2
    printf '%s\n' "$pn_lines" | sed 's/^/      /' >&2
    printf '\n' >&2
  fi
  pn_advice
  return 1
}
