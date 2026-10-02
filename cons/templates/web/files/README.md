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
installed on the system, but `cons bin` needs the one the tree built: it copies that libuv
beside `bin/{{name}}`, with its license under `bin/LICENSES/`, and stops with exit code 3,
naming the command to run, if the app would load a system copy instead. The binary looks for
libuv beside itself, so copy `bin/` as a whole to run it on another machine. To use another
server,
replace `hyperion/server-uv` in `{{name}}.asd` with `clack-handler-hunchentoot`, which needs
nothing installed.

Tasks are declared in `cons.lisp` (the cross-OS Makefile replacement). Config/env:
copy `.env.example` to `.env` and fill it in -- it loads via `cons/env:load-dotenv`
(the host environment wins in prod).

## Commits

No `Co-Authored-By` trailers naming an AI assistant -- see `AGENTS.md` (Attribution) for
where AI's role is recorded instead. A `commit-msg` hook enforces it; wire it once, after
`git init`:

    git config core.hooksPath .githooks

Scaffolded by `cons init`.
