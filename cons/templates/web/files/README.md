# {{name}}

TODO: one-line description.

## Develop

    cons build   # compile
    cons test    # run tests
    cons repl    # SBCL REPL with the tree on the path{{run-line}}
    cons         # list all targets

The app serves on `hyperion/server-uv`, Ouranos's own HTTP server, which runs on libuv.
Build libuv once in the Ouranos tree (`sbcl --script scripts/build-libuv.lisp` from its
root). Running from source (`cons build`, `cons dev`, `cons serve`) also works with a libuv
installed on the system, but `cons bin` needs the one the tree built. To use another server,
replace `hyperion/server-uv` in `{{name}}.asd` with `clack-handler-hunchentoot`, which needs
nothing installed.

`cons bin` copies the native libraries the tree builds into `bin/`, beside `bin/{{name}}`, for
each one the app loads: libuv, mbedTLS (for TLS) and libgit2 (for `aion/libgit`). Each library's
licence goes under `bin/LICENSES/`. libgit2's licence, the GPL version 2 with a linking
exception, requires its source to be available wherever the binary is distributed, so its
pinned source tarball goes under `bin/SOURCES/`. The binary looks for these libraries beside
itself, so copy `bin/` as a whole, including `bin/LICENSES/` and `bin/SOURCES/`, to run it on
another machine or to distribute it. `cons bin` stops with exit code 3, naming the command to
run, if the app would load one of these libraries from a system copy instead of the one the
tree built.

Tasks are declared in `cons.lisp` (the cross-OS Makefile replacement). Config/env:
copy `.env.example` to `.env` and fill it in -- it loads via `cons/env:load-dotenv`
(the host environment wins in prod).

## Commits

No `Co-Authored-By` trailers naming an AI assistant -- see `AGENTS.md` (Attribution) for
where AI's role is recorded instead. A `commit-msg` hook enforces it; wire it once, after
`git init`:

    git config core.hooksPath .githooks

Scaffolded by `cons init`.
