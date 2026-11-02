#!/usr/bin/env sh
# check-install-names.sh --- the install name of each dylib a macOS bundle carries (#957, #1131).
#
#     scripts/check-install-names.sh <dir>
#
# Check 1b of verify-bundle-macos.sh, which runs it on the directory holding the bundle's
# executables and dylibs. It is a script of its own so that a test can run it on a directory of
# real dylibs without building or launching an app.
#
# A dylib built outside the bundle keeps the path it was built at as its own install name.
# Nothing loads the carried copy by that name, so that is a WARN rather than a FAIL, but the
# shipped file would carry a path from the build machine. The bundler stamps such a name
# @executable_path/<name> (scripts/carry-natives.lisp, STAMP-INSTALL-NAME).
#
# Prints one line per dylib: ok, WARN or FAIL. Exits 1 if any line is a FAIL: otool could not
# read the file, or the file has no install name. Exits 2 on a bad command line.

set -eu

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <dir>" >&2
  exit 2
fi
# Without a trailing slash, so that "$DIR"/* below matches an install name inside it.
DIR=${1%/}
FAILED=0

for f in "$DIR"/*.dylib; do
  [ -f "$f" ] || continue
  # Fails rather than passes when the id cannot be read: without the Command Line Tools,
  # /usr/bin/otool is a stub that exits non-zero and prints nothing (#958's review).
  if ! OUT=$(otool -D "$f" 2>&1); then
    echo "  FAIL -- otool -D could not read $(basename "$f"): $OUT"
    FAILED=1
    continue
  fi
  # otool prints a header line, the file's path and a colon, then the install name. For a
  # universal dylib it prints a header and an install name per architecture, so only line 2 is
  # read. A file with no install name gets the header alone, so line 2 is empty. Before #1131
  # this read `head -n 2 | tail -n 1', which returned the header in that case; the header
  # starts with the bundle directory, so a missing install name was reported as ok.
  ID=$(printf '%s\n' "$OUT" | sed -n 2p)
  case "$ID" in
    "")
      echo "  FAIL -- otool -D printed no install name for $(basename "$f")"
      FAILED=1 ;;
    "$DIR"/*) echo "  ok -- $(basename "$f"): $ID" ;;
    /*)
      echo "  WARN -- $(basename "$f") has the install name $ID, a path outside the bundle."
      echo "          The current bundler stamps it @executable_path/$(basename "$f") (#957)." ;;
    *) echo "  ok -- $(basename "$f"): $ID" ;;
  esac
done

exit "$FAILED"
