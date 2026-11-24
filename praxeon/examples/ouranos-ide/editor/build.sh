#!/usr/bin/env sh
# build.sh --- build the Ouranos IDE editor bundle from the pinned npm packages (#1218).
#
#   praxeon/examples/ouranos-ide/editor/build.sh
#
# Only a maintainer who changes src/editor.js or a package version runs this. Running the IDE,
# its tests and CI use the committed bundle and need neither Node nor npm.
#
# It runs `npm ci`, which installs exactly the versions in package-lock.json into
# node_modules/ in this directory and nowhere else, with install scripts turned off. Then
# esbuild bundles src/editor.js and the CodeMirror packages into one minified file,
# ouranos-editor.min.js. It writes:
#
#   ouranos-editor.min.js          the bundle the IDE serves
#   ouranos-editor.min.js.sha256   its SHA-256, which a test in the IDE's suite compares with
#                                  the bundle, so a bundle edited by hand or left stale fails
#   THIRD-PARTY-LICENSES.txt       the licence of every package in the bundle
#
# and prints the SHA-256. Commit all three, then update the bundle's row in
# docs/dependencies.md.
#
# Needs: node and npm on the PATH, and shasum or sha256sum.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

command -v npm >/dev/null 2>&1 || { echo "build.sh: npm is not on the PATH" >&2; exit 2; }

npm ci --ignore-scripts --no-audit --no-fund

./node_modules/.bin/esbuild src/editor.js \
  --bundle --minify --format=iife --target=es2020 --charset=utf8 \
  --legal-comments=eof \
  --banner:js='/* Ouranos IDE editor: CodeMirror 6 and its dependencies, bundled by build.sh from src/editor.js. MIT licences in THIRD-PARTY-LICENSES.txt. Do not edit by hand. */' \
  --outfile=ouranos-editor.min.js

# The licence file of every package in the bundle: the lock file's packages that are not
# development dependencies, which leaves out esbuild and its platform binaries.
node -e '
const fs = require("fs");
const path = require("path");
const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
let text = "Licences of the npm packages bundled into ouranos-editor.min.js, as installed from package-lock.json by build.sh.\n";
for (const [where, info] of Object.entries(lock.packages).sort()) {
  if (!where || info.dev) continue;
  const name = where.replace(/^node_modules\//, "");
  const files = fs.readdirSync(where).filter((f) => /^licen[cs]e/i.test(f));
  if (files.length === 0) throw new Error("no licence file in " + where);
  text += "\n==== " + name + " " + info.version + " (" + info.license + ") ====\n\n";
  text += fs.readFileSync(path.join(where, files[0]), "utf8").trim() + "\n";
}
fs.writeFileSync("THIRD-PARTY-LICENSES.txt", text);
'

if command -v shasum >/dev/null 2>&1; then
  sum=$(shasum -a 256 ouranos-editor.min.js | cut -d' ' -f1)
else
  sum=$(sha256sum ouranos-editor.min.js | cut -d' ' -f1)
fi
printf '%s  ouranos-editor.min.js\n' "$sum" > ouranos-editor.min.js.sha256

bytes=$(wc -c < ouranos-editor.min.js | tr -d ' ')
echo "ouranos-editor.min.js: $bytes bytes"
echo "sha256: $sum"
