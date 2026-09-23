# aion/uv/process — subprocesses and signals

Third sub-system, after [uv-design.md](uv-design.md) (loop, fs, timers, watching) and
[uv-net-design.md](uv-net-design.md) (TCP, pipes, DNS). Binding only: **orchestration
belongs to the consumer.**

## What it is for

`cons` runs build and test targets as subprocesses today, through `uiop:run-program`,
which **blocks**. A target's output arrives in a lump when the process exits, so a
five-minute compile looks like five minutes of nothing followed by everything at once.
`uv_spawn` with piped stdio makes it arrive as it is produced.

That consumer is `cons`, at **DAG position 2** — which is the whole reason this binding
cannot live any further right, and the concrete case behind the decisions-log rule that
native bindings follow the DAG while abstractions follow the domain. Deciding *what* to
run, in what order, and what to do when it fails is `cons`'s business. Starting it is
this system's.

## The stdio is the stream layer's

A child's stdin, stdout and stderr are `uv_pipe_t`, and a `uv_pipe_t` **is** a
`uv_stream_t`. So they come back as ordinary `aion/uv/net` `CONNECTION`s, and
`start-reading`, `write-bytes`, `pipe-into` and the whole backpressure apparatus apply
with no additions.

This matters more than it sounds. A child that writes faster than the parent consumes is
*exactly* the unbounded-buffer situation that made Node rewrite its stream layer twice —
and here it is already solved one layer down, by a `pipe-into` that pauses the producer at
the high-water mark. Depending on `aion/uv/net` is therefore the design, not a
convenience: the alternative is a second, worse implementation of streams inside a process
API.

The one addition needed was `net:make-pipe-connection` — an initialised but unconnected
`uv_pipe_t` — because a child's pipe is joined by `uv_spawn` rather than by a connect.

## Direction words are from the child's point of view

The single most confusing thing in libuv's process API:

| descriptor | child does | libuv flag | parent does |
|---|---|---|---|
| stdin (0) | **reads** | `UV_CREATE_PIPE \| UV_READABLE_PIPE` | writes |
| stdout (1) | **writes** | `UV_CREATE_PIPE \| UV_WRITABLE_PIPE` | reads |
| stderr (2) | **writes** | `UV_CREATE_PIPE \| UV_WRITABLE_PIPE` | reads |

Getting it backwards produces a child that hangs rather than an error, which is why there
is a test that writes to a child's stdin and reads it back out of its stdout.

## How a process ended is one fact reported as two numbers

libuv hands the exit callback an `exit_status` **and** a `term_signal`, and reading either
alone is wrong:

> **A process killed by SIGKILL has an exit status of 0.**

So the obvious check — status zero means success — reports that a build killed mid-run
succeeded. This is the same shape of bug as treating end-of-stream as a failure in
`aion/uv/net`, and it gets the same treatment: a `Termination` ADT in which `Exited` and
`Killed` cannot be collapsed, and a `succeeded-p` that consults both. `exit-status` is
still exposed, and its docstring says plainly that it is meaningless on its own.

## Signals, and why through libuv

A `uv_signal_t` handler runs as an **ordinary loop callback, on the loop thread, with a
full Lisp stack** — not in a signal context, where the set of things it is safe to do is
small and exceeding it produces something other than an error message. That is the same
property that makes every callback in this binding safe, applied to the one case where
CL's own facility is most dangerous.

**The signal table is deliberately partial.** Only signals whose *number* is identical on
Linux and macOS are named: `:hup :int :quit :abrt :kill :pipe :alrm :term :winch`.
`SIGUSR1`/`SIGUSR2` (10/12 vs 30/31) and `SIGCHLD` (17 vs 20) are omitted rather than given
a number that is right on one platform and silently wrong on the other — the same
reasoning that makes the rest of the binding classify errors by name instead of errno. An
unnamed keyword is refused; a number always works.

**A started signal handle holds the loop open.** For a supervisor — the `service` target
kind (#25) — that is exactly right. For a script it is the classic surprise, and
`(uv:describe-loop l)` names the handle responsible.

**A trap worth knowing:** libuv restores `SIG_DFL` when the last handle for a signal
stops. A test that unwatches `SIGINT` and then sends itself `SIGINT` therefore *kills the
test runner* rather than asserting anything. The suite uses `SIGWINCH` throughout, whose
default action is to ignore — the one signal safe to send at yourself in either state.

## Process groups

The only portable group control libuv offers is `UV_PROCESS_DETACHED`, which makes the
child a group leader. After that, `kill-pid` with a **negative** pid reaches the group on
unix — which is how you reach the *grandchildren* a shell-invoked target spawns. `kill` on
the process handle only ever reaches the child itself.

## The hand-written structs

`uv_process_options_t` and `uv_stdio_container_t` are written out by hand, which the
no-grovel rule permits because they are **libuv's own** — it invents them to normalise
process creation across three very different operating systems, so their shape is libuv's
to keep stable. Contrast `struct addrinfo` in `aion/uv/net`, which is the platform's and
therefore had to be guarded at runtime.

Two mitigations make this lower-risk than it looks:

1. `uv_process_options_t` is an **input** struct. We fill it and hand it over; libuv never
   hands one back. A layout mistake produces a failed spawn with a bad argument, not a
   silent misread of memory libuv owns.
2. The only place the platform leaks in is `uv_uid_t` / `uv_gid_t` — `unsigned char` on
   Windows, `uid_t`/`gid_t` elsewhere. Both are written out, and they are the **last two
   fields**, so an error there cannot shift anything that matters.

## What is not built yet

- **`uv_queue_work`.** Still deliberately unbound, for the third time: its work function
  runs on a genuinely foreign threadpool thread, the one place the "callbacks only on
  SBCL-created threads" rule would break. We have real threads; we do not need a pool.
- **`UV_PROCESS_SETUID` / `SETGID`.** Bound as constants, not exposed in `spawn` — nothing
  needs them, and dropping privileges deserves its own thought rather than a keyword.
- **stdio beyond three descriptors.** libuv supports an arbitrary `stdio_count`; we fix it
  at 3 because nothing has asked for more.
- **Verification on macOS and Windows.** The suite passes on Linux/WSL. **Windows is where
  this API diverges most** — process creation there is a genuinely different model
  (no fork/exec, argument quoting is the caller's problem, `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS`
  exists because of it), and named pipes are not unix domain sockets. The test suite is
  POSIX-only as written: it invokes `/bin/sh`, `/bin/echo` and `/bin/cat`. Making it
  cross-platform is part of the CI matrix work (#87), and should be done by abstracting
  the test programs rather than by assuming they exist.
