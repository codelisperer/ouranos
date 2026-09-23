#!/usr/bin/env sh
# verify-clean-machine.sh --- run the documented getting-started sequence on a machine that
# has never had SBCL, Quicklisp or Coalton on it, and PROVE it never had them (#198).
#
#   scripts/verify-clean-machine.sh                 # this checkout's branch, ubuntu:24.04
#   scripts/verify-clean-machine.sh --image debian:12
#   scripts/verify-clean-machine.sh --ref main
#
# WHY THIS EXISTS. #88 verified bootstrap.lisp from a clean TREE, but neither of its legs
# was a clean OPERATING SYSTEM -- both redirected XDG_* to get a clean tree on a machine
# that already had the toolchain. So the step BEFORE bootstrap, the one that provisions
# SBCL and Quicklisp, had never run anywhere that lacked them. CI cannot cover it either:
# runners arrive with a toolchain, which is precisely the condition being tested against.
#
# It found a real failure on its first run -- see the curl commentary in setup.sh.
#
# WHAT IT ASSERTS, and why each assertion is here rather than left to the reader:
#
#   1. COLDNESS, BEFORE ANYTHING RUNS. `command -v sbcl` must fail, and ~/quicklisp,
#      ~/common-lisp and ~/.cache/common-lisp must not exist. A cold-machine test whose
#      coldness is unverified measures the wrong thing in the direction that produces a
#      false pass -- AGENTS.md, "Green is not evidence".
#
#   2. THE PREREQUISITE MESSAGE NAMES EVERYTHING AT ONCE. Phase 1 gives the container git
#      and nothing else, then asserts setup.sh's refusal mentions BOTH curl and bzip2. A
#      script that reports them one per run sends a reader on a fresh machine round the
#      loop repeatedly, and that regression is invisible to any test that pre-installs
#      the tools.
#
#   3. THE OUTCOME, NOT THE EXIT CODE. bin/cons must exist and run, AND bootstrap must
#      report no failed step. "Exited 0" is not "it worked" -- the first version of this
#      script checked only the exit code and reported PASS on a run where mnemosyne could
#      not load at all. See the commentary at phase 6.
#
# Linux only, deliberately. macOS and Windows are reasoned rather than measured here: both
# would need a VM this repo does not provision, and setup.ps1 is the Windows lane's.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
image=ubuntu:24.04
ref=""

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image=$2; shift 2;;
    --ref)   ref=$2; shift 2;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    *) echo "verify-clean-machine.sh: unknown option $1" >&2; exit 2;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  echo "verify-clean-machine.sh: docker is required (this test IS a fresh operating system)" >&2
  exit 2
}

# Clone from THIS machine's repository rather than from GitHub, so the run tests the code in
# front of you instead of whatever is on the remote -- and so it needs no credentials for a
# private repo. A worktree's .git is a FILE pointing into the main repository, which cannot
# be cloned through a bind mount, so mount the common dir's repository instead.
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
mainrepo=$(dirname "$common")
[ -n "$ref" ] || ref=$(git -C "$root" rev-parse --abbrev-ref HEAD)

echo "==> clean-machine verification"
echo "    image : $image"
echo "    repo  : $mainrepo"
echo "    ref   : $ref"

docker run --rm -v "$mainrepo:/main:ro" -e REF="$ref" "$image" sh -c '
set -eu
export DEBIAN_FRONTEND=noninteractive

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== 1. COLDNESS (asserted, not assumed) ==="
command -v sbcl >/dev/null 2>&1 && fail "sbcl is already present -- this is not a clean machine"
[ -e "$HOME/quicklisp" ]           && fail "$HOME/quicklisp exists"
[ -e "$HOME/common-lisp" ]         && fail "$HOME/common-lisp exists"
[ -e "$HOME/.cache/common-lisp" ]  && fail "$HOME/.cache/common-lisp exists (a fasl cache)"
echo "ok   no sbcl, no ~/quicklisp, no ~/common-lisp, no fasl cache"
echo "     stock image ships: curl=$(command -v curl || echo NONE) bzip2=$(command -v bzip2 || echo NONE) sudo=$(command -v sudo || echo NONE) tar=$(command -v tar || echo NONE)"
echo "     running as uid=$(id -u)"

echo
echo "=== 2. git, because the documented first command is a clone ==="
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq git >/dev/null 2>&1
git config --global --add safe.directory "*"
git clone -q -b "$REF" /main /work
cd /work
echo "ok   cloned $REF at $(git rev-parse --short HEAD)"

echo
echo "=== 3. setup.sh must name EVERY missing tool in one pass ==="
out=$(./scripts/setup.sh 2>&1) && fail "setup.sh succeeded without curl -- it cannot have"
echo "$out" | sed "s/^/     | /"
echo "$out" | grep -q "curl"  || fail "the refusal does not mention curl"
echo "$out" | grep -q "bzip2" || fail "the refusal mentions curl but NOT bzip2 -- serial discovery is back"
echo "ok   both named in one run"

echo
echo "=== 4. provision ==="
apt-get install -y -qq curl bzip2 >/dev/null 2>&1
./scripts/setup.sh || fail "setup.sh failed"
echo "ok   setup.sh exited 0"

echo
echo "=== 5. setup.sh reported success it had earned ==="
./scripts/setup.sh --check >/dev/null || fail "setup.sh exited 0 but --check disagrees"
echo "ok   --check agrees the machine is provisioned"

echo
echo "=== 6. bootstrap.lisp, the documented next command ==="
PATH="$HOME/.local/bin:$PATH"; export PATH
SBCL_HOME="$HOME/.local/lib/sbcl"; export SBCL_HOME
sbcl --dynamic-space-size 4096 --script bootstrap.lisp 2>&1 | tee /tmp/bootstrap.log
grep -q "^bootstrap: saving cons" /tmp/bootstrap.log || fail "bootstrap.lisp did not build bin/cons"

# BOOTSTRAPS EXIT 0 WITH A BROKEN TREE, and this assertion is here because the FIRST
# version of this script did not have it and reported PASS on exactly that. The warm step
# is deliberately non-fatal -- it is an optimisation -- so a system that cannot load prints
# "warm step exited 1 -- continuing" and the script carries on to a clean exit. On a stock
# ubuntu:24.04 that hid a missing libsqlite3: setup.sh 0, bootstrap 0, bin/cons built and
# running, and mnemosyne unable to load at all. Checking the exit code proves nothing here;
# the printed line is the only place it shows.
if grep -q "warm step exited" /tmp/bootstrap.log; then
  grep -nE "Unable to load|warm step exited" /tmp/bootstrap.log | sed "s/^/     | /"
  fail "the warm step failed -- the tree does not load, whatever the exit code says"
fi
echo "ok   bootstrap completed with no failed step"

echo
echo "=== 7. the OUTCOME, not the exit code ==="
[ -x bin/cons ] || fail "bin/cons was not produced"
./bin/cons version || fail "bin/cons does not run"
echo "ok   bin/cons exists and runs"

echo
echo "CLEAN MACHINE: PASS"
'
