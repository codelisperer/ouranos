#!/usr/bin/env sh
# build-sbcl.sh --- build SBCL from the source sbcl.pin names, test it, and package it (#1251).
#
#   scripts/build-sbcl.sh [--xc-host "COMMAND"] [--work DIR] [--out DIR] [--skip-tests]
#                         [--static-zstd | --system-zstd]
#
#   --xc-host     the Lisp that compiles the first build. Default: "sbcl --disable-debugger
#                 --no-sysinit --no-userinit", which is make.sh's own default. Any SBCL works;
#                 it affects only the first build (see "Two builds" below).
#   --work        where the source is cloned and built. Default: a new directory under $TMPDIR.
#                 It must not exist yet, so that no earlier build's files are reused.
#   --out         where the package, its .sha256 file and the build record are written.
#                 Default: dist/sbcl under the tree. Created if missing.
#   --skip-tests  do not run SBCL's own test suite. For trying the script out only: the
#                 workflow never passes it, and the build record says the tests were skipped.
#   --static-zstd build libzstd.a from the zstd release sbcl.pin names and link the runtime with
#                 it, so the machine that runs SBCL needs no libzstd. The default on macOS.
#   --system-zstd link the build machine's libzstd dynamically. The default on Linux, where
#                 every Debian and Ubuntu system has libzstd.so.1.
#
# .github/workflows/sbcl-build.yml runs this on each platform. It runs on Linux and macOS; the
# Windows build (MSYS2) is not written yet. It writes, into --out:
#   sbcl-<version>-ouranos.<release>-<arch>-<os>-binary.tar.bz2
#   sbcl-<version>-ouranos.<release>-<arch>-<os>-binary.tar.bz2.sha256   (sha256sum's format)
#   sbcl-<version>-ouranos.<release>-<arch>-<os>-build.txt               (how it was built)
# The tarball has the layout of SBCL's own binary releases (binary-distribution.sh), with the
# top directory sbcl-<version>-<arch>-<os>/ holding install.sh, so scripts/setup.sh can install
# it the way it installs an upstream tarball.
#
# Build options. They were proposed in #1251 and checked against make-config.sh at the tag
# sbcl-2.6.10 (comment on #1251, 2026-11-16):
#   --dynamic-space-size=4096   the default heap. Upstream's is 1024 MB, which is why every
#                               command in this tree passes --dynamic-space-size 4096.
#   --with-sb-thread            already on by default for x86-64 Linux and macOS and for arm64;
#                               passed so the command says so.
#   --with-sb-core-compression  zstd-compressed cores for save-lisp-and-die, on every platform.
#                               The runtime links libzstd: dynamically on Linux, where every
#                               Debian or Ubuntu system has it (libzstd1 is Priority: required),
#                               and statically on macOS and Windows, where a user's machine does
#                               not (ouranos-pm's ruling on #1251, 2026-11-17). The build fails
#                               when a static build still lists libzstd as a dependency.
#                               Upstream's binary is built without compression.
# Everything else is make.sh's default for the platform.
#
# Two builds, as SBCL's own release.sh does. The first is compiled by --xc-host, which can be any
# SBCL, such as the distribution's package. The second is compiled by the first, so the binary
# that ships was compiled by the SBCL version it is. The tests run on the second build, which is
# the one that ships.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

xc_host="sbcl --disable-debugger --no-sysinit --no-userinit"
work=""
out="$root/dist/sbcl"
run_tests=1
zstd_link=""
while [ $# -gt 0 ]; do
  case "$1" in
    --xc-host) xc_host=$2; shift 2;;
    --work) work=$2; shift 2;;
    --out) out=$2; shift 2;;
    --skip-tests) run_tests=0; shift;;
    --static-zstd) zstd_link=static; shift;;
    --system-zstd) zstd_link=system; shift;;
    -h|--help) sed -n '2,52p' "$0"; exit 0;;
    *) echo "build-sbcl.sh: unknown option $1" >&2; exit 2;;
  esac
done

info() { printf '==> %s\n' "$1"; }
die() { echo "build-sbcl.sh: $1" >&2; exit 1; }

# --- the pin -------------------------------------------------------------------------------
pin_field() {
  awk -v k="$1" '$1 == k {print $2; exit}' "$root/sbcl.pin"
}
version=$(pin_field version)
repo=$(pin_field repo)
tag=$(pin_field tag)
commit=$(pin_field commit)
release=$(pin_field release)
zstd_version=$(pin_field zstd-version)
zstd_url=$(pin_field zstd-url)
zstd_sha256=$(pin_field zstd-sha256)
for v in version repo tag commit release zstd_version zstd_url zstd_sha256; do
  eval "[ -n \"\$$v\" ]" || die "sbcl.pin has no $(echo $v | tr _ -) line"
done

# --- the platform ----------------------------------------------------------------------------
case "$(uname -s)" in
  Linux) os=linux;;
  Darwin) os=darwin;;
  *) die "this script builds on Linux and macOS; the Windows build is not written yet (#1251)";;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86-64;;
  arm64|aarch64) arch=arm64;;
  *) die "no SBCL build is set up for $(uname -m)";;
esac

[ -n "$zstd_link" ] || case "$os" in linux) zstd_link=system;; *) zstd_link=static;; esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

base="sbcl-$version-$arch-$os"
name="sbcl-$version-ouranos.$release-$arch-$os"
options="--dynamic-space-size=4096 --with-sb-thread --with-sb-core-compression"

if [ -z "$work" ]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/build-sbcl.XXXXXX")
else
  [ ! -e "$work" ] || die "--work $work already exists; give a new directory"
  mkdir -p "$work"
fi
work=$(cd "$work" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
src="$work/$base"
log="$work/build.log"
info "building SBCL $version (ouranos.$release) for $arch-$os in $work"

# --- the source, at the pinned commit --------------------------------------------------------
info "cloning $repo at $tag"
git clone --quiet --depth 1 --branch "$tag" "$repo" "$src"
got=$(git -C "$src" rev-parse HEAD)
[ "$got" = "$commit" ] || die "$repo's tag $tag is commit $got, but sbcl.pin pins $commit; refusing to build it"
info "source is $commit, as pinned"
# Built from a tree with no .git, as SBCL's source releases are. Without .git,
# generate-version.sh takes the version from version.lisp-expr, so `sbcl --version' prints
# exactly the pinned version; from a git checkout it would add a commit count and hash.
rm -rf "$src/.git"
printf '"%s"\n' "$version" > "$src/version.lisp-expr"

# --- libzstd.a, for a static build -----------------------------------------------------------
# Built from the pinned zstd release and put first on the compiler's search paths. A linker
# looks for -lzstd in its library directories in order, so it takes this libzstd.a before any
# libzstd in a later directory, such as the /opt/homebrew/lib that SBCL's macOS Config appends.
# The header comes from the same release, so the header and the library agree.
if [ "$zstd_link" = static ]; then
  info "building libzstd.a from zstd $zstd_version"
  zsrc="$work/zstd-src"
  zdir="$work/zstd-static"
  mkdir -p "$zsrc" "$zdir/lib" "$zdir/include"
  curl -fsSL --retry 4 --retry-all-errors --connect-timeout 20 --max-time 300 \
       -o "$work/zstd.tar.gz" "$zstd_url" || die "downloading $zstd_url failed"
  got=$(sha256_of "$work/zstd.tar.gz")
  [ "$got" = "$zstd_sha256" ] || die "$zstd_url has SHA-256 $got, but sbcl.pin pins $zstd_sha256"
  tar -xzf "$work/zstd.tar.gz" -C "$zsrc" --strip-components 1
  make -C "$zsrc/lib" libzstd.a >>"$work/zstd.log" 2>&1 \
    || { tail -20 "$work/zstd.log" >&2; die "building libzstd.a failed"; }
  cp "$zsrc/lib/libzstd.a" "$zdir/lib/"
  cp "$zsrc/lib/zstd.h" "$zsrc/lib/zstd_errors.h" "$zdir/include/"
  LIBRARY_PATH="$zdir/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  CPATH="$zdir/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH CPATH
  zstd_record="$zstd_version (BSD licence), linked statically from $zstd_url (SHA-256 $zstd_sha256)"
else
  zstd_record="the build machine's libzstd, linked dynamically (BSD licence); pkg-config says $(pkg-config --modversion libzstd 2>/dev/null || echo 'nothing')"
fi
info "zstd: $zstd_record"

# The host reads forms from standard input, as make.sh drives it, so its REPL prompt and banner
# come out too; the marked line is the answer.
host_version=$(echo '(format t "~&HOST-VERSION ~A ~A~%" (lisp-implementation-type) (lisp-implementation-version))' \
                 | $xc_host 2>/dev/null | sed -n 's/^[* ]*HOST-VERSION //p' | head -1 || true)
[ -n "$host_version" ] || die "the host Lisp does not run: $xc_host"
info "host Lisp for the first build: $xc_host (version $host_version)"

# --- first build, compiled by the host Lisp --------------------------------------------------
info "first build (log: $log)"
# shellcheck disable=SC2086  # $options is a word list on purpose
(cd "$src" && sh make.sh $options --xc-host="$xc_host") >"$log" 2>&1 \
  || { tail -40 "$log" >&2; die "the first build failed; the last 40 lines of $log are above"; }
stage1="$work/stage1"
mkdir -p "$stage1"
cp "$src/src/runtime/sbcl" "$stage1/sbcl"
cp "$src/output/sbcl.core" "$stage1/sbcl.core"

# --- second build, compiled by the first ------------------------------------------------------
info "second build, compiled by the first"
(cd "$src" && sh clean.sh) >>"$log" 2>&1
# shellcheck disable=SC2086
(cd "$src" && sh make.sh $options \
   --xc-host="$stage1/sbcl --core $stage1/sbcl.core --disable-debugger --no-sysinit --no-userinit") \
  >>"$log" 2>&1 \
  || { tail -40 "$log" >&2; die "the second build failed; the last 40 lines of $log are above"; }

# --- what the built SBCL says about itself -----------------------------------------------------
run_sbcl() { (cd "$src" && sh run-sbcl.sh --noinform --non-interactive --no-sysinit --no-userinit "$@"); }
# --version is a runtime option, so it must come before any Lisp option; run_sbcl adds those.
said=$( (cd "$src" && sh run-sbcl.sh --version) 2>&1 | head -1)
[ "$said" = "SBCL $version" ] || die "the built SBCL reports \"$said\", not \"SBCL $version\""
facts=$(run_sbcl --eval '(progn
  (format t "~&FEATURES~{ ~(~A~)~}~%" (remove-if-not (lambda (f) (member f (list :sb-thread :sb-core-compression :sb-unicode :sb-safepoint))) *features*))
  (format t "HEAP-MB ~D~%" (floor (sb-ext:dynamic-space-size) 1048576)))' 2>&1)
echo "$facts"
features=$(echo "$facts" | sed -n 's/^FEATURES //p')
heap=$(echo "$facts" | sed -n 's/^HEAP-MB //p')
case " $features " in *" sb-thread "*) ;; *) die "the built SBCL has no :sb-thread";; esac
case " $features " in *" sb-core-compression "*) ;; *) die "the built SBCL has no :sb-core-compression";; esac
[ "$heap" = "4096" ] || die "the built SBCL's default heap is ${heap:-unknown} MB, not 4096"
contribs=$(cd "$src/obj/sbcl-home/contrib" && ls ./*.fasl | sed 's|^\./||; s|\.fasl$||' | tr '\n' ' ')
case "$arch" in
  # make-config.sh leaves sb-simd out when the BUILD machine has no AVX2. A build on such a
  # machine would ship without it, silently; this makes that a failure instead.
  x86-64) case " $contribs " in *" sb-simd "*) ;; *) die "sb-simd was not built (no AVX2 on this build machine?)";; esac;;
esac

# The libraries the runtime needs on the machine that runs it, and on Linux the newest glibc
# symbol version it uses, which is the oldest glibc it runs on.
if [ "$os" = linux ]; then
  needed=$(readelf -d "$src/src/runtime/sbcl" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')
  glibc=$(objdump -T "$src/src/runtime/sbcl" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
else
  needed=$(otool -L "$src/src/runtime/sbcl" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')
  glibc="n/a"
fi
# The oldest macOS the runtime runs on, from its LC_BUILD_VERSION load command.
minos="n/a"
if [ "$os" = darwin ]; then
  minos=$(otool -l "$src/src/runtime/sbcl" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "minos" {print $2; exit}')
fi
if [ "$zstd_link" = static ]; then
  case "$needed" in *zstd*) die "the runtime was meant to link libzstd statically, but it needs: $needed";; esac
fi
info "runtime needs: $needed"
info "newest glibc symbol: $glibc"
info "oldest macOS: $minos"

# --- SBCL's own tests, on the build that ships --------------------------------------------------
tests="skipped (--skip-tests)"
if [ "$run_tests" -eq 1 ]; then
  info "running SBCL's test suite (log: $work/tests.log)"
  (cd "$src/tests" && sh run-tests.sh) >"$work/tests.log" 2>&1 \
    || { tail -60 "$work/tests.log" >&2; die "SBCL's test suite failed; the last 60 lines of $work/tests.log are above"; }
  tests="passed, no unexpected failures ($(grep -c '^ *\(Expected failure\|Skipped (broken)\):' "$work/tests.log" || true) tests listed as expected failures or skipped as broken)"
  info "tests $tests"
fi

# --- the package ---------------------------------------------------------------------------------
info "packaging $name-binary.tar.bz2"
(cd "$work" && sh "$src/binary-distribution.sh" "$base") >>"$log" 2>&1
bzip2 -9 -c "$work/$base-binary.tar" > "$out/$name-binary.tar.bz2"
(cd "$out" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name-binary.tar.bz2"
              else shasum -a 256 "$name-binary.tar.bz2"; fi) > "$out/$name-binary.tar.bz2.sha256"

cc_version=$( (cc --version 2>/dev/null || echo unknown) | head -1)
cat > "$out/$name-build.txt" <<EOF
SBCL $version, Ouranos build $release, for $arch-$os
source:        $repo, tag $tag, commit $commit
options:       $options (everything else is make.sh's default)
host Lisp:     $xc_host, version $host_version (first build only)
second build:  compiled by the first build
C compiler:    $cc_version
build machine: $(uname -srm)
features:      $features
default heap:  $heap MB
contribs:      $contribs
runtime needs: $needed
newest glibc:  $glibc
oldest macOS:  $minos
zstd:          $zstd_record
SBCL tests:    $tests
package:       $(cat "$out/$name-binary.tar.bz2.sha256")
EOF
cat "$out/$name-build.txt"
info "done: $out/$name-binary.tar.bz2"
