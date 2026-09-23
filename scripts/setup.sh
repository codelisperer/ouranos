#!/usr/bin/env sh
# setup.sh --- provision a bare Linux/macOS machine (or a CI runner) for Ouranos.
#
#   ./scripts/setup.sh            install what is missing, at the pinned versions
#   ./scripts/setup.sh --check    report only; exit 1 if something is missing
#   ./scripts/setup.sh --ci       as above, plus export PATH/env for GitHub Actions
#
# Installs, all at the versions pinned in scripts/versions.env:
#   1. SBCL      -- Linux: the official binary tarball, into $SBCL_PREFIX (no sudo).
#                   macOS: Homebrew (upstream ships no macOS binaries -- see docs/ci.md).
#   2. Quicklisp -- into ~/quicklisp, with the dist pinned to a dated snapshot.
#   3. Coalton   -- a git checkout at the pinned commit in ~/common-lisp/coalton
#                   (it is NOT a Quicklisp system; ASDF finds ~/common-lisp by default).
# It does NOT run bootstrap.lisp -- that is the next step, and the caller's choice:
#   sbcl --dynamic-space-size 4096 --script bootstrap.lisp
#
# Idempotent: anything already present at the right version is left alone.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
check_only=0
ci=0
for arg in "$@"; do
  case "$arg" in
    --check) check_only=1;;
    --ci)    ci=1;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "setup.sh: unknown option $arg" >&2; exit 2;;
  esac
done

# --- the pins ---------------------------------------------------------------
# shellcheck disable=SC2046  # deliberate: KEY=VALUE lines, no quoting/expansion
eval $(grep -E '^[A-Z_]+=' "$here/versions.env")
: "${SBCL_VERSION:?versions.env: SBCL_VERSION missing}"
: "${QUICKLISP_DIST:?versions.env: QUICKLISP_DIST missing}"

# Coalton's commit comes from the repo-root coalton.pin -- the single source of truth for it
# across every machine (docs/coalton-upstream.md). Deliberately NOT duplicated in
# versions.env: two files naming a Coalton commit is the drift this pin exists to prevent.
COALTON_REF=$(awk '/^sha[[:space:]]/ {print $2; exit}' "$root/coalton.pin" 2>/dev/null || true)
[ -n "$COALTON_REF" ] || { echo "setup.sh: no 'sha' line in $root/coalton.pin" >&2; exit 1; }
# An optional `repo` line lets the pin name a FORK. Without it we track upstream. This
# matters because a sha alone is only meaningful relative to a repository: a machine cloned
# from upstream and one cloned from a fork can disagree about what a sha even refers to.
COALTON_REPO=$(awk '/^repo[[:space:]]/ {print $2; exit}' "$root/coalton.pin" 2>/dev/null || true)
[ -n "$COALTON_REPO" ] || COALTON_REPO="https://github.com/coalton-lang/coalton"

prefix="${SBCL_PREFIX:-$HOME/.local}"
ql_home="${QUICKLISP_HOME:-$HOME/quicklisp}"
coalton_dir="${COALTON_DIR:-$HOME/common-lisp/coalton}"
os=$(uname -s)

info() { printf '==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
missing=0
need() { printf '  MISSING %s\n       fix: %s\n' "$1" "$2" >&2; missing=$((missing+1)); }

# Where sbcl actually is: PATH first, then our own install prefix. That second case matters
# more than it looks -- we install to ~/.local/bin, which is NOT on PATH in a non-login
# shell, so without this the doctor cannot see the SBCL it installed one line earlier and
# tells you to run setup.sh again. Forever.
sbcl_bin() {
  if have sbcl; then command -v sbcl
  elif [ -x "$prefix/bin/sbcl" ]; then echo "$prefix/bin/sbcl"
  fi
}
sbcl_version() {
  b=$(sbcl_bin)
  [ -n "$b" ] || { echo ''; return; }
  "$b" --version 2>/dev/null | awk '{print $2}'
}

# ONE scratch directory and ONE trap. There used to be two: install_sbcl set an EXIT trap
# for its tmpdir and install_quicklisp then REPLACED it with one for its own, so the SBCL
# tarball and its unpacked tree (~90 MB) were never cleaned up. A second `trap ... EXIT`
# does not add a handler, it overwrites the first.
scratch=""
# `return 0' is not decoration. An EXIT trap whose last command fails can leak that status
# as the script's, and the failing command here is the ordinary case: `test -n ""' when
# nothing was ever downloaded. A provisioning script that exits non-zero after succeeding
# is the exact dishonesty the rest of this file is being fixed for.
cleanup() { [ -n "$scratch" ] && rm -rf "$scratch"; return 0; }
trap cleanup EXIT
need_scratch() { [ -n "$scratch" ] || scratch=$(mktemp -d); }

# Download, and RETRY WHAT ACTUALLY GOES WRONG.
#
# `--retry N` alone was not enough, and the gap is documented rather than inferred: curl(1)
# says a transient error "means either: a timeout, an FTP 4xx response code or an HTTP 408,
# 429, 500, 502, 503, 504, 522 or 524 response code." A mirror that accepts the request and
# then closes MID-TRANSFER is exit 18 (partial file), which is in none of those categories,
# so curl gave up on the first occurrence despite --retry 4.
#
# That is not hypothetical: the first ever clean-machine run of this script (#198) died
# exactly there, on a real SourceForge mirror, after 3m23s -- with `curl: (18) transfer
# closed with 11526315 bytes remaining to read` and nothing installed.
#
# --retry-all-errors covers it. The timeouts matter as much: without them a stalled mirror
# hangs indefinitely with no output, which is what those 3m23s looked like from outside.
# And the failure now names WHAT was being downloaded -- a bare curl error code does not
# tell a reader on a fresh machine which of three downloads just died.
fetch() {
  _url=$1; _out=$2; _what=$3
  curl -fsSL --retry 6 --retry-delay 2 --retry-all-errors \
       --connect-timeout 20 --max-time 900 -o "$_out" "$_url" \
    || { echo "setup.sh: downloading $_what failed (curl exit $?)" >&2
         echo "         $_url" >&2
         echo "         a transient mirror failure is the usual cause -- re-run setup.sh" >&2
         exit 1; }
}

# --- 1. SBCL ----------------------------------------------------------------
install_sbcl() {
  case "$os" in
    Linux)
      arch=$(uname -m)
      case "$arch" in
        x86_64) sbcl_arch=x86-64;;
        aarch64|arm64) sbcl_arch=arm64;;
        *) echo "setup.sh: no upstream SBCL binary for $arch -- build from source" >&2; exit 1;;
      esac
      tarball="sbcl-$SBCL_VERSION-$sbcl_arch-linux-binary.tar.bz2"
      url="https://downloads.sourceforge.net/project/sbcl/sbcl/$SBCL_VERSION/$tarball"
      # The upstream tarball is .tar.bz2, and tar shells out to the bzip2 BINARY to unpack
      # it. A minimal image (WSL, containers, CI base images) often has tar but not bzip2,
      # and the failure -- "tar (child): bzip2: Cannot exec" -- names tar, not the missing
      # package.
      have bzip2 || { echo "setup.sh: bzip2 is required to unpack the SBCL tarball (sudo apt install bzip2)" >&2; exit 1; }
      info "installing SBCL $SBCL_VERSION -> $prefix"
      need_scratch
      fetch "$url" "$scratch/$tarball" "SBCL $SBCL_VERSION"
      tar -xjf "$scratch/$tarball" -C "$scratch"
      (cd "$scratch/sbcl-$SBCL_VERSION-$sbcl_arch-linux" && INSTALL_ROOT="$prefix" sh install.sh >/dev/null)
      note "sbcl -> $prefix/bin/sbcl   (SBCL_HOME=$prefix/lib/sbcl)"
      ;;
    Darwin)
      # Upstream publishes NO macOS binaries (the 2.6.6 release carries linux + windows
      # only), so the version pin cannot be honoured here -- brew decides.
      have brew || { echo "setup.sh: Homebrew required on macOS (https://brew.sh)" >&2; exit 1; }
      info "installing SBCL via Homebrew (upstream ships no macOS binary; version is brew's)"
      brew list sbcl >/dev/null 2>&1 || brew install sbcl
      ;;
    *) echo "setup.sh: unsupported OS $os (Windows: use scripts/setup.ps1)" >&2; exit 1;;
  esac
}

# --- system libraries the tree binds at LOAD time ---------------------------
#
# Not build dependencies: a plain `ql:quickload' needs them, and without them the failure
# is a CFFI "Unable to load any of the alternatives" deep inside ASDF, naming a soname
# rather than a package anyone can install.
#
#   libev      -- Woo, praxeon/web's Clack handler on Unix (#218).
#   libsqlite3 -- cl-sqlite, under mnemosyne's default backend.
#
# LIBSQLITE3 IS HERE BECAUSE THE CLEAN-MACHINE RUN FOUND IT (#198), and it is the better
# illustration of why this list exists. On a stock ubuntu:24.04 the documented sequence
# reported success end to end -- setup.sh exited 0, bootstrap.lisp exited 0, bin/cons was
# built and ran -- while mnemosyne could not load AT ALL. bootstrap's warm step is an
# optimisation and deliberately non-fatal, so it printed "warm step exited 1 -- continuing"
# and carried on. Nothing in the sequence a reader is told to run said the tree was broken.
#
# macOS needs neither: brew's Woo pulls libev, and libsqlite3 ships with the OS.

as_root=""
root_ready=""
ensure_root() {
  if [ -z "$root_ready" ]; then
    if [ "$(id -u)" = "0" ]; then as_root=""; root_ready=yes
    elif have sudo && sudo -n true 2>/dev/null; then as_root="sudo -n"; root_ready=yes
    else root_ready=no
    fi
  fi
  [ "$root_ready" = yes ]
}

# THREE cases, and the old code collapsed two of them into the wrong one: it asked
# `sudo -n true' and, on failure, said "sudo needs a password". As ROOT with no sudo binary
# -- every stock container, and the machine this was first measured on -- that is wrong
# twice over: root needs no sudo, and there is no sudo there to want a password.
ensure_lib() {
  _pat=$1; _apt=$2; _dnf=$3; _pac=$4; _why=$5
  case "$os" in
    Linux)
      if ldconfig -p 2>/dev/null | grep -q "$_pat"; then note "$_apt present"; return 0; fi
      ensure_root || {
        note "$_apt missing and this shell cannot get root -- run: sudo apt install $_apt  ($_why)"
        return 0
      }
      info "installing $_apt ($_why)"
      # shellcheck disable=SC2086  # $as_root is a command prefix, empty when we are root
      if have apt-get; then
        $as_root apt-get update -qq >/dev/null 2>&1 || true
        $as_root apt-get install -y "$_apt" >/dev/null 2>&1 || note "apt-get failed; install $_apt by hand"
      elif have dnf; then $as_root dnf install -y "$_dnf" >/dev/null 2>&1 || note "dnf failed; install $_dnf by hand"
      elif have pacman; then $as_root pacman -S --noconfirm "$_pac" >/dev/null 2>&1 || note "pacman failed; install $_pac by hand"
      else note "install $_apt yourself ($_why): apt $_apt | dnf $_dnf | pacman $_pac"
      fi
      ;;
    Darwin)
      case "$_apt" in
        libev-dev)
          brew list libev >/dev/null 2>&1 && { note "libev present"; return 0; }
          info "installing libev (Woo)"
          brew install libev
          ;;
        *) : ;;   # libsqlite3 ships with macOS
      esac
      ;;
  esac
}

install_system_libs() {
  ensure_lib 'libev\.so'      libev-dev     libev-devel     libev    "Woo needs it to load hyperion"
  ensure_lib 'libsqlite3\.so' libsqlite3-dev libsqlite3-devel sqlite3 "cl-sqlite needs it to load mnemosyne"
}

export_sbcl_env() {
  case "$os" in
    Linux)
      PATH="$prefix/bin:$PATH"; export PATH
      SBCL_HOME="$prefix/lib/sbcl"; export SBCL_HOME
      if [ "$ci" -eq 1 ] && [ -n "${GITHUB_PATH:-}" ]; then
        echo "$prefix/bin" >> "$GITHUB_PATH"
        echo "SBCL_HOME=$prefix/lib/sbcl" >> "${GITHUB_ENV:-/dev/null}"
      fi
      ;;
  esac
}

# --- 2. Quicklisp -----------------------------------------------------------
install_quicklisp() {
  info "installing Quicklisp -> $ql_home"
  need_scratch
  fetch https://beta.quicklisp.org/quicklisp.lisp "$scratch/quicklisp.lisp" "quicklisp.lisp"
  sbcl --non-interactive --no-userinit --load "$scratch/quicklisp.lisp" \
       --eval "(quicklisp-quickstart:install :path \"$ql_home/\")" >/dev/null
}

pin_quicklisp_dist() {
  current=$(awk -F': *' '/^version:/{print $2}' "$ql_home/dists/quicklisp/distinfo.txt" 2>/dev/null || echo '')
  [ "$current" = "$QUICKLISP_DIST" ] && { note "Quicklisp dist $current (pinned)"; return 0; }
  info "pinning Quicklisp dist $current -> $QUICKLISP_DIST"
  sbcl --non-interactive --no-userinit --load "$ql_home/setup.lisp" \
       --eval "(ql-dist:install-dist \"http://beta.quicklisp.org/dist/quicklisp/$QUICKLISP_DIST/distinfo.txt\" :replace t :prompt nil)" >/dev/null
}

# --- 3. Coalton -------------------------------------------------------------
install_coalton() {
  if [ -d "$coalton_dir/.git" ]; then
    # coalton.pin carries a SHORT sha, so compare RESOLVED commit ids -- a string compare
    # against HEAD's full sha never matches and would re-checkout on every run.
    current=$(git -C "$coalton_dir" rev-parse HEAD 2>/dev/null || echo "")
    want=$(git -C "$coalton_dir" rev-parse "$COALTON_REF^{commit}" 2>/dev/null || echo "")
    if [ -n "$want" ] && [ "$current" = "$want" ]; then note "Coalton already at the pinned $COALTON_REF"; return 0; fi
    info "fetching Coalton -> $COALTON_REF"
    git -C "$coalton_dir" fetch --quiet origin
  else
    info "cloning Coalton from $COALTON_REPO -> $coalton_dir"
    mkdir -p "$(dirname "$coalton_dir")"
    git clone --quiet "$COALTON_REPO" "$coalton_dir"
  fi
  # A checkout pointing at a different remote than the pin declares will fetch shas that do
  # not exist there (or, worse, DIFFERENT commits with the same short prefix). Say so.
  origin=$(git -C "$coalton_dir" remote get-url origin 2>/dev/null || echo "")
  if [ -n "$origin" ] && [ "$origin" != "$COALTON_REPO" ]; then
    note "WARNING: $coalton_dir tracks $origin but coalton.pin declares $COALTON_REPO"
  fi
  git -C "$coalton_dir" checkout --quiet "$COALTON_REF" || {
    echo "setup.sh: commit $COALTON_REF not found in $coalton_dir (wrong remote, or fetch failed)" >&2
    exit 1
  }
}

# Install the Quicklisp releases Coalton's compiler depends on, before anything loads Coalton.
#
# Quicklisp installs a dist system's dependencies before loading it, because the dist lists
# them. Coalton is a git checkout, not a dist system, so Quicklisp finds its dependencies one
# error at a time. `coalton/library' has `:defsystem-depends-on ("coalton-asdf")', which loads
# coalton-compiler while ASDF is still reading coalton.asd, so each missing release raises
# MISSING-DEPENDENCY inside that form. Quicklisp installs the release and retries, and SBCL
# prints "While evaluating the form starting at line 23 ... compilation unit aborted" for
# each one: four times on a fresh machine, twice in the release job (#8). It is harmless, but
# it looks exactly like a real error. The list is read from coalton-compiler.asd, so it
# follows the Coalton pin. Loading that .asd does not load its dependencies, and on a machine
# that already has them this step only checks.
install_coalton_deps() {
  sbcl --non-interactive --no-userinit --load "$ql_home/setup.lisp" \
       --eval "(asdf:load-asd \"$coalton_dir/coalton-compiler.asd\")" \
       --eval '(ql:quickload (asdf:system-depends-on (asdf:find-system "coalton-compiler")) :silent t)' \
       >/dev/null || {
    echo "setup.sh: installing the Quicklisp releases Coalton depends on failed" >&2
    exit 1
  }
  note "Coalton's Quicklisp dependencies are installed"
}

# --- report / act -----------------------------------------------------------
info "Ouranos setup on $os ($(uname -m)) -- pins: SBCL $SBCL_VERSION, QL dist $QUICKLISP_DIST, Coalton $COALTON_REF"

# THE DOCTOR, as a function, because it is now called TWICE: for `--check', and again at
# the END of an install to verify that the install actually worked.
#
# That second call is the point. `setup.sh' used to exit 0 while leaving the machine
# unprovisioned -- libev needs root, and when it could not get root it printed a note and
# returned success. getting-started.md then tells the reader to run bootstrap.lisp, which
# quickloads praxeon, which declares clack-handler-woo, which binds libev at LOAD time. So
# the documented sequence was "setup succeeds, the next command fails", and the script had
# a doctor that knew better sitting right next to the installer that did not ask it (#198).
#
# Returns 0 when the machine is provisioned, 1 otherwise. Never exits: the caller decides.
run_doctor() {
  missing=0
  have curl || need "curl" "your package manager (apt install curl / brew install curl)"
  have git  || need "git"  "apt install git   |  brew install git"
  have tar  || need "tar"  "apt install tar"
  # Linux only: the SBCL tarball is bz2-compressed and tar needs the bzip2 binary for it.
  if [ "$os" = "Linux" ] && ! have bzip2; then need "bzip2 (to unpack the SBCL tarball)" "sudo apt install bzip2"; fi
  v=$(sbcl_version)
  if [ -z "$v" ]; then need "SBCL" "./scripts/setup.sh   (installs $SBCL_VERSION)"
  elif [ "$v" != "$SBCL_VERSION" ] && [ "$os" != "Darwin" ]; then
    printf '  WARN    SBCL %s installed, pin is %s\n' "$v" "$SBCL_VERSION"
  else printf '  PASS    SBCL %s\n' "$v"; fi
  # Installed but invisible to a plain shell is a different problem from missing, and needs
  # a different fix -- say which.
  if [ -n "$v" ] && ! have sbcl; then
    printf '  WARN    sbcl is at %s but NOT on PATH\n       fix: export PATH="%s/bin:$PATH" SBCL_HOME="%s/lib/sbcl"\n' \
           "$(sbcl_bin)" "$prefix" "$prefix"
  fi
  if [ -f "$ql_home/setup.lisp" ]; then printf '  PASS    Quicklisp at %s\n' "$ql_home"
  else need "Quicklisp" "./scripts/setup.sh"; fi
  # Checking the directory EXISTS is not enough: a checkout at the wrong commit is the exact
  # drift coalton.pin exists to catch, and it is invisible until something behaves oddly.
  if [ -d "$coalton_dir/.git" ]; then
    ch=$(git -C "$coalton_dir" rev-parse HEAD 2>/dev/null || echo "")
    want=$(git -C "$coalton_dir" rev-parse "$COALTON_REF^{commit}" 2>/dev/null || echo "")
    if [ -n "$want" ] && [ "$ch" = "$want" ]; then printf '  PASS    Coalton at %s (pinned %s)\n' "$coalton_dir" "$COALTON_REF"
    elif [ -z "$want" ]; then need "Coalton pin $COALTON_REF not in $coalton_dir" "./scripts/setup.sh   (fetches, or the remote is wrong)"
    else need "Coalton is at $(echo "$ch" | cut -c1-8), pin says $COALTON_REF" "./scripts/setup.sh"; fi
  else need "Coalton checkout" "./scripts/setup.sh"; fi
  printf '      (deep check -- which Coalton actually LOADS: sbcl --script scripts/check-coalton.lisp)\n'
  # libev is a LOAD-time dependency of hyperion on Unix (Woo binds it via CFFI), so a
  # machine without it looks fine until `ql:quickload :hyperion` dies.
  case "$os" in
    Linux)  if ldconfig -p 2>/dev/null | grep -q 'libev\.so'; then printf '  PASS    libev (Woo)\n'
            else need "libev (Woo needs it to load hyperion)" "sudo apt install libev-dev  |  dnf install libev-devel"; fi
            # Checked here as well as installed above, because the doctor is what decides
            # whether setup.sh may claim success -- and this is the one the clean-machine
            # run caught the whole sequence lying about (#198).
            if ldconfig -p 2>/dev/null | grep -q 'libsqlite3\.so'; then printf '  PASS    libsqlite3 (mnemosyne)\n'
            else need "libsqlite3 (cl-sqlite needs it to load mnemosyne)" "sudo apt install libsqlite3-dev  |  dnf install libsqlite3-devel"; fi;;
    Darwin) if brew list libev >/dev/null 2>&1; then printf '  PASS    libev (Woo)\n'
            else need "libev (Woo needs it to load hyperion)" "brew install libev"; fi
            printf '  PASS    libsqlite3 (ships with macOS)\n';;
  esac
  [ "$missing" -eq 0 ]
}

if [ "$check_only" -eq 1 ]; then
  run_doctor || { echo "setup.sh: missing prerequisites (see above)." >&2; exit 1; }
  info "this machine is provisioned."
  exit 0
fi

# THE HOST TOOLS, ALL AT ONCE. This used to be two `exit 1`s in a row, so a bare machine
# discovered its prerequisites SERIALLY: install curl, re-run, learn about bzip2, re-run.
# Measured on a stock ubuntu:24.04, which ships none of curl, bzip2 or sudo. `--check' has
# always reported the whole list in one pass; there was no reason for the install path to
# be worse at it than the doctor standing beside it.
missing=0
have curl || need "curl" "apt install curl   |  brew install curl"
have git  || need "git"  "apt install git    |  brew install git"
have tar  || need "tar"  "apt install tar"
if [ "$os" = "Linux" ] && ! have bzip2; then need "bzip2 (to unpack the SBCL tarball)" "apt install bzip2"; fi
[ "$missing" -eq 0 ] || {
  echo "setup.sh: install the above first, then re-run. That is the whole list, not the first item." >&2
  exit 1
}

v=$(sbcl_version)
if [ -z "$v" ]; then
  install_sbcl
elif [ "$v" != "$SBCL_VERSION" ] && [ "$os" = "Linux" ]; then
  note "SBCL $v found, pin is $SBCL_VERSION -- installing the pinned build alongside it"
  install_sbcl
else
  note "SBCL $v present"
fi
export_sbcl_env
install_system_libs
[ -f "$ql_home/setup.lisp" ] || install_quicklisp
pin_quicklisp_dist
install_coalton
install_coalton_deps

# ASK THE DOCTOR RATHER THAN ASSERTING SUCCESS. "Exited 0" and "it worked" are different
# claims, and this script used to make the first while sounding like the second.
info "verifying"
if ! run_doctor; then
  echo "setup.sh: provisioning did NOT complete -- see the gaps above." >&2
  echo "         bootstrap.lisp will fail on these, so it is not the next step yet." >&2
  exit 1
fi

info "provisioned. Next: sbcl --dynamic-space-size 4096 --script bootstrap.lisp   (from $root)"
if [ "$ci" -eq 0 ] && [ "$os" = "Linux" ]; then
  note "if sbcl is not on your PATH: export PATH=\"$prefix/bin:\$PATH\" SBCL_HOME=\"$prefix/lib/sbcl\""
fi
