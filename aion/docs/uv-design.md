# `aion/uv` — libuv, bound for Common Lisp

The design narrative for the libuv binding: what it is, the decisions that shaped it,
and the things that will bite whoever touches it next. Status lives on the
[Roadmap board](https://github.com/orgs/codelisperer/projects/1)
([#84](https://github.com/codelisperer/ouranos/issues/84)).

## What it is

An event loop, filesystem operations in **both** synchronous and asynchronous forms,
timers, and cross-platform filesystem watching — with a typed Coalton core and an
idiomatic CL shell.

> **The decisions live in two places, deliberately.** This document holds the *founding*
> five (§"The five decisions") — how the binding is built and why it is safe. The
> *strategy* — why libuv at all, what we will never bind, how the work is sequenced, and
> when we would stop — is [`adr/0002`](adr/0002-libuv-integration-strategy.md), with the
> stream contract in [`adr/0001`](adr/0001-stream-contract.md). Start at 0002 for the whole
> picture.

```lisp
(uv:read-file "/etc/hostname" :as :string)      ; synchronous. No loop, no setup.

(uv:with-loop (l)                               ; asynchronous
  (let ((f (uv:read-file-async l "/etc/hostname")))
    (uv:run l)
    (uv:await f)))

(uv:with-loop (l)                               ; watching
  (uv:watch l "src/" (lambda (events name w)
                       (declare (ignore w))
                       (format t "~A ~A~%" events name)))
  (uv:start-loop-thread l))
```

## Why it lives in aion

aion is the leftmost framework in the DAG, so it is the only place a capability every
other framework may use can live. The precedent is `aion/log`, which is likewise
effectful and likewise an **opt-in aux system**: core aion stays a pure functional
library with two dependencies, and consumers who want an event loop ask for `aion/uv`
explicitly. Nothing that does not name it pays for it.

## The five decisions

### 1. Built from source, pinned — not `apt install libuv1-dev`

`libuv.pin` names the version, URL and sha256; `scripts/build-libuv.lisp` fetches,
verifies and compiles it into `vendor/libuv/` (git-ignored). The pin is committed, the
artifact is not.

This is ADR-0011 paid forward. Woo bound **libev** at load time, so every Linux and
macOS desktop bundle CI produced was dead on arrival on a clean machine —
`libev.so.4: cannot open shared object file`. The lesson generalises: *a native
dependency you do not build is one you cannot bundle*, and the failure lands on the
user rather than on us. Building it ourselves also means all three platforms run one
version rather than Ubuntu's 1.51.0, brew's whatever, and MSYS2's something else.

### 2. No cmake, no make — one compiler invocation

libuv ships a cmake build. We do not use it. Compiling libuv is a list of C files, a
handful of `-D` defines and some link flags, all of which the build script holds
per-platform (transcribed from libuv's own `CMakeLists.txt`; re-check them when bumping
the pin). `sbcl --script` drives `cc` directly.

That keeps the house rule — no make / just / nmake anywhere — and reduces the new
prerequisite from "a build system" to "a C compiler", which every machine that ships a
desktop bundle already has. It takes about five seconds.

### 3. No grovelling — sizes at runtime, enums verified at load

The usual way to bind C is to run a compiler at build time to learn struct layouts
(`cffi-grovel`). We do not, because that would put a C toolchain on the **load** path of
a system six frameworks might depend on. Instead:

- **Sizes** come from libuv itself: `uv_loop_size()`, `uv_handle_size(type)`,
  `uv_req_size(type)`. libuv exports these precisely so bindings need not know its
  layouts. We allocate by asking.
- **Layouts** are hand-written only for the structs libuv defines *itself* rather than
  inheriting from the platform — `uv_buf_t`, `uv_stat_t`, `uv_dirent_t`. `uv_stat_t` is
  libuv's own normalisation of `stat(2)`, identical on every platform, which is what
  makes hand-writing it safe and would not if it were the OS's `struct stat`.
- **Enum values** are hardcoded (they are ABI: appended to, never reordered) and then
  **verified at load** against `uv_handle_type_name` / `uv_req_type_name`. If upstream
  ever does reorder, we fail loudly instead of silently allocating a handle at the wrong
  size — which is the failure that corrupts memory and surfaces somewhere unrelated.

The one genuinely platform-varying constant set is the `O_*` open flags, which expand to
the platform's own values. SBCL groveled those when *it* was built, so we read them from
`sb-posix` rather than guessing.

### 4. Sync and async are both real, and the split is libuv's

Every `uv_fs_*` function takes a callback as its last argument. Pass `NULL` and libuv
runs the operation **inline on the calling thread**; pass a callback and it goes to the
threadpool with completion delivered on the loop thread. Node's `readFileSync` versus
`readFile` is built on exactly this — Node exposed the pattern, it did not invent it.

Reading libuv's `POST` macro settles an important question: in the synchronous branch it
calls `uv__fs_work` inline and does **not** call `uv__req_register(loop)`, so no loop
state is touched. Therefore our synchronous calls need no loop at all and are safe from
any thread, even while another thread runs a loop. `(uv:read-file path)` just works,
with no setup.

**The naming is deliberately inverted from Node.** JavaScript has no threads, so
blocking is the exceptional and dangerous choice and earns the `Sync` marker. SBCL has
real threads; blocking is ordinary. So the plain name is the direct one and `-ASYNC`
marks the specialised form.

Note what libuv does *not* offer: streams (TCP/UDP/pipe/tty), timers, `fs_event`,
signals and processes are **async-only**. Node has no synchronous form for them either.
Where a blocking call is wanted there, it has to be synthesised (submit, then run the
loop until completion) — and should be named so nobody mistakes it for free.

### 5. Callbacks re-enter Lisp only on Lisp threads

The genuine hazard in binding libuv is not the API surface, it is the callbacks. Three
rules keep it safe, and they are written at the top of `loop.lisp` too:

1. **A loop is owned by one thread.** libuv is not thread-safe. The single exception it
   documents is `uv_async_send`, so that is the only door in from outside — `uv:submit`
   queues a closure and knocks on it.
2. **Callbacks arrive on a thread SBCL created.** libuv invokes callbacks from whichever
   thread runs `uv_run`, and we only ever run loops on SBCL threads, so callbacks
   re-enter Lisp on a stack that already exists. (libuv's threadpool threads *are*
   foreign, but they run the *work* function, never our completion callback — and we
   never hand libuv a work function.)
3. **No condition may unwind into C.** A Lisp error escaping a callback would unwind
   through a foreign frame: undefined behaviour, not an error message. Every callback
   body is wrapped in `with-callback-guard`.

A fourth, quieter rule governs memory: **whatever we allocate, we free; whatever libuv
allocates, its own cleanup frees.** Nothing is freed across that boundary. On Windows a
mingw-built libuv and SBCL may not share a C runtime, where a cross-boundary free is not
a leak but a crash. Handle memory is freed in the *close callback*, never eagerly — libuv
goes on using a handle throughout teardown.

Lisp objects are never stored in foreign memory (not even in the `data` field libuv
provides for it): SBCL's GC moves objects, so a pointer parked in C would go stale
silently. A registry keyed by pointer address maps back to the owning Lisp object.

## The typed core

`aion/uv/types` is aion's first `coalton-toplevel`, and it is not decoration. libuv
speaks in integers — a bitmask for what changed about a file, a negative number for what
went wrong — and integers are where silent bugs live. The Coalton layer decodes them
into ADTs, once, at the boundary. It is pure; no IO, per the house rule.

Two things it gets right that are easy to get wrong in CL:

- `fs_event` delivers a **bitmask**, so rename and change can both be set. `FileEvent`
  is decoded to a *list*; a plain enum would have to invent a "both" case or drop one.
- Errors are classified by libuv's **name** (`"ENOENT"`), never its number. The numbers
  are platform errnos and differ across Linux, macOS and Windows; the names do not.
  Binding behaviour to the numbers is how a wrapper works on the machine it was written
  on and misbehaves everywhere else.

Each ADT has a monomorphic CL-callable renderer beside it (`classify-error-name`,
`file-event-strings`), so callers who never write Coalton still get decoding that was
type-checked — the pure-CL face from `docs/coalton-patterns.md` §5.

## What is not built yet

Named honestly, because a binding that implies more coverage than it has is worse than a
small one:

- **UDP and TTY.** TCP, pipes and DNS landed in `aion/uv/net` (pre-publication issue 118 — see
  [uv-net-design.md](uv-net-design.md)); processes and signals landed in
  `aion/uv/process` (pre-publication issue 119 — [uv-process-design.md](uv-process-design.md)). UDP
  (`uv_udp_t`) and TTY are what remain of the stream surface, and neither has a consumer
  asking for it yet.
  *`aion/uv/net` was built to honour [`adr/0001-stream-contract.md`](adr/0001-stream-contract.md),
  written before it: backpressure is half the read API rather than a later addition (Node
  rewrote streams three times over exactly that), `TCP_NODELAY` is set, and `uv_walk` is
  bound so a live loop can be inspected from a REPL. The strategy those sit under is
  [`adr/0002`](adr/0002-libuv-integration-strategy.md).*
- **`uv_queue_work`.** Deliberately absent: its work function runs on a *foreign*
  threadpool thread, which is the one place rule 2 above would be violated.
- **Bundling into desktop artifacts** (#78) and the CI matrix (pre-publication issue 87).
- **`hyperion/dev` adoption.** #84 nominated the hot-reload watcher as the first real
  consumer; the watcher exists here, the swap has not been made.

## Gotchas for the next person

- **Linux `:recursive` is a lie you must not tell.** inotify is not recursive, so libuv
  watches only the named directory. macOS and Windows honour it. `watch` documents this
  rather than silently walking the tree.
- **One editor save is not one event.** Editors differ — some truncate in place, some
  write a temp file and rename over the target — so a save may arrive as one event or
  three. Consumers that need "the file settled" must debounce; the right quiet period
  depends on what is being watched, so it belongs to the consumer.
- **The filename can be NIL.** Some backends only report that *something* changed.
- **`uv_run :once` returns immediately if nothing is referenced.** The loop thread keeps
  its wakeup handle referenced for exactly this reason; without it the thread spins at
  100% CPU while idle. Plain `run` leaves it unreferenced so it can terminate.
- **A short read is normal.** `uv_fs_read` may return fewer bytes than asked for; the
  read path loops. The test suite uses a 300 KB file specifically to exercise it.
