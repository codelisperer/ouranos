#!/bin/sh
# publish-public.sh --- build the public repo as a single fresh commit (no history).
#
# The decision (pre-publication issue 90): the private history names client and product work in 188 diff lines
# and 12 commit messages, spread from the first commit through the subtree-merged originals
# -- including a merge commit whose title names a client organization. Rewriting 217 commits
# would preserve provenance nobody reads, at the cost of invalidating every SHA and having
# to be redone immediately before the flip. So the public repo starts clean instead:
#
#   this repo (private)  -- keeps full history, forever, as the record
#   public repo          -- one initial commit of the working tree, no history to sweep
#
# There is nothing to redact after this runs, because there is nothing but the tree.
#
# Usage:
#   scripts/publish-public.sh --check                     # verify only; writes nothing
#   scripts/publish-public.sh --out ../ouranos-public     # build the publishable tree
#   scripts/publish-public.sh --out DIR --remote git@github.com:codelisperer/ouranos-public.git
#
# The remote must be a DIFFERENT repository from this one. This script builds an orphan
# history in a fresh `git init`, so pushing it at this repo's own origin is rejected as
# non-fast-forward -- or, forced, destroys the full history that the decision above says
# is kept privately forever. The check below refuses that remote rather than trusting
# whoever reads this comment.
#
# It never pushes on its own: it prints the push command for you to run deliberately.

set -eu

OUT=""
REMOTE=""
CHECK_ONLY=0
TAG="v0.1.0"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  CHECK_ONLY=1 ;;
    --out)    OUT="$2"; shift ;;
    --remote) REMOTE="$2"; shift ;;
    --tag)    TAG="$2"; shift ;;
    *) echo "publish-public.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Refuse to publish at this repository's own remote. The usage example above used to name it,
# and a fresh orphan history pushed there either fails or erases the record.
if [ -n "$REMOTE" ]; then
  PRIVATE_ORIGIN=$(git remote get-url origin 2>/dev/null || true)
  norm() { printf '%s' "$1" | sed -e 's#^git@\([^:]*\):#https://\1/#' -e 's#\.git$##' -e 's#/$##'; }
  if [ -n "$PRIVATE_ORIGIN" ] && [ "$(norm "$REMOTE")" = "$(norm "$PRIVATE_ORIGIN")" ]; then
    echo "publish-public.sh: --remote is this repository's own origin." >&2
    echo "  The public repo must be a SEPARATE repository. Pushing an orphan history here" >&2
    echo "  would fail, or with --force would destroy the private history this repo keeps" >&2
    echo "  as the record (see the note at the top of this file)." >&2
    exit 1
  fi
fi

# The names that must never appear publicly are read from a PRIVATE, gitignored file --
# deliberately not inlined here. A detector that lists the secrets it looks for publishes
# them the moment it is published itself, which is exactly the mistake this script exists to
# prevent (and which an earlier draft of this file made). One regex alternation per line, or
# a single alternation; blank lines and # comments are ignored.
NAMES_FILE="${OURANOS_PRIVATE_NAMES:-$ROOT/.private-names}"
if [ ! -f "$NAMES_FILE" ]; then
  echo "publish-public.sh: no private-names file at $NAMES_FILE" >&2
  echo "  This check fails CLOSED: without the list it cannot verify anything." >&2
  echo "  Create it (it is gitignored), one name or regex per line." >&2
  exit 1
fi
# sed removes trailing whitespace, including the carriage return a Windows editor saves at
# the end of each line; left in place, it makes that entry match nothing, without any error.
# Same fix as .githooks/private-names.sh.
PATTERN=$(sed 's/[[:space:]]*$//' "$NAMES_FILE" | grep -vE '^\s*(#|$)' | paste -sd '|' -)
if [ -z "$PATTERN" ]; then
  echo "publish-public.sh: $NAMES_FILE is empty -- refusing to run a check that cannot fail" >&2
  exit 1
fi

fail=0

say()  { printf '%s\n' "$*"; }
pass() { printf '  PASS    %s\n' "$*"; }
bad()  { printf '  FAIL    %s\n' "$*"; fail=1; }

say "==> publish-public: verifying the working tree"

# 1. The tree must be clean, or we would publish something not under review.
if [ -n "$(git status --porcelain)" ]; then
  bad "working tree is dirty -- commit or stash first"
else
  pass "working tree is clean"
fi

# 2. No client/product names anywhere in the tracked tree. This is the whole point.
hits=$(git grep -inE "$PATTERN" -- . 2>/dev/null | grep -viE 'example\.com' || true)
if [ -n "$hits" ]; then
  bad "client/product names in the tree:"
  printf '%s\n' "$hits" | head -20 | sed 's/^/            /'
else
  pass "no client or product names in the tracked tree"
fi

# 3. Untracked-but-present files are not published, but a stray .env would be a disaster
#    if someone later runs `git add -A` in the published copy. Warn loudly.
if [ -f .env ]; then
  say "  NOTE    a .env exists here; it is gitignored and will NOT be copied"
fi

# 4. A LICENSE is a publication prerequisite (pre-publication issue 85).
if [ -f LICENSE ] || [ -f LICENSE.md ] || [ -f LICENSE.txt ]; then
  pass "LICENSE present"
else
  bad "no LICENSE file (see pre-publication issue 85) -- do not publish without one"
fi

# 4a. ...and one per framework. Each is its own ASDF system, each already declares
# :license in its .asd, and each can plausibly be vendored or read on its own -- a
# directory claiming MIT in metadata with no license text beside it is not actually
# licensed to whoever ends up holding it. Checking only the root passed for months
# while all seven were missing, which is why this is a separate check.
missing_license=""
for asd in */*.asd; do
  [ -e "$asd" ] || continue
  d=${asd%/*}
  case "$d" in .*) continue ;; esac
  if [ ! -f "$d/LICENSE" ] && [ ! -f "$d/LICENSE.md" ] && [ ! -f "$d/LICENSE.txt" ]; then
    missing_license="$missing_license $d"
  fi
done
if [ -n "$missing_license" ]; then
  bad "framework(s) declare :license but carry no LICENSE file:$missing_license"
else
  pass "every framework carries a LICENSE"
fi

if [ "$fail" -ne 0 ]; then
  say "==> refusing to continue."
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "==> checks passed; nothing written (--check)."
  exit 0
fi

if [ -z "$OUT" ]; then
  say "==> checks passed. Re-run with --out DIR to build the publishable tree."
  exit 0
fi

if [ -e "$OUT" ]; then
  say "publish-public.sh: $OUT already exists -- remove it or choose another path" >&2
  exit 1
fi

say "==> building $OUT"

# Export the tracked tree at HEAD -- tracked files only, so nothing ignored or untracked
# can ride along by accident. This is why we do not simply copy the directory.
mkdir -p "$OUT"
git archive --format=tar HEAD | (cd "$OUT" && tar xf -)

cd "$OUT"
git init -q
git add -A

# Belt and braces: check the STAGED content too, in case .gitattributes or export-ignore
# rules changed what actually landed.
staged_hits=$(git diff --cached | grep -inE "$PATTERN" | grep -viE 'example\.com' || true)
if [ -n "$staged_hits" ]; then
  say "  FAIL    client/product names survived into the staged tree:"
  printf '%s\n' "$staged_hits" | head -20 | sed 's/^/            /'
  exit 1
fi
say "  PASS    staged content is clean"

git commit -q -m "Ouranos $TAG — seven co-evolving Common Lisp / Coalton frameworks

CL all the way down: a typed Coalton core with an effectful CL shell, pluggable backends
behind neutral protocols, and no external build tooling.

  aion → cons → mnemosyne → elenchon → hyperion → praxeon, plus hermes

Published from a fresh commit rather than the development history; the full history is
retained privately. See README.md and ECOSYSTEM.md."

git tag -a "$TAG" -m "Ouranos $TAG"

if [ -n "$REMOTE" ]; then
  git remote add origin "$REMOTE"
fi

say "==> built $OUT"
say "    commits: $(git rev-list --count HEAD)  (expected: 1)"
say "    tag:     $TAG"
say ""
say "    Review it, then push deliberately:"
say "      cd $OUT"
if [ -z "$REMOTE" ]; then
  say "      git remote add origin <public-repo-url>"
fi
say "      git push -u origin HEAD:main --tags"
