---
title: "20,000 Leagues under the C"
date: 2026-08-04
status: draft
tags: [common-lisp, coalton, libuv, ffi, cffi, systems-programming]
series: "20,000 Leagues under the C"
summary: >
  Binding libuv to Common Lisp without a groveller, without CMake, and without asking anyone
  to install MSYS2. Low-level reach without low-level exposure — and an honest account of
  what it does not do yet.
---

> *Mobilis in Mobile* — "moving within the moving element." The device engraved on the
> Nautilus.
>
> **[DRAFT NOTE: editions differ between *Mobilis in Mobili* and *Mobilis in Mobile*. Pick
> one deliberately before publishing and say which. There is a second Verne line about
> confusing statics with dynamics that would fit the Coalton section — UNVERIFIED, do not
> use until located in the actual text.]**

# 20,000 Leagues under the C

Every high-level language eventually goes down to the C. It has to: the operating system's
interface is a C interface, and no amount of taste at the top changes what is at the bottom.
The interesting question is not whether you descend. It is what you bring back up, and how
much of the pressure you make everyone else feel.

Common Lisp has historically made everyone feel all of it. This is the story of binding
**libuv** — the event loop underneath Node.js — to CL, and of three decisions that keep the
descent from surfacing in anybody's build.

## The usual story, and why it is bad

The standard way to bind a C library in CL is `cffi-grovel`. You write a small specification,
grovel compiles a C program at build time, runs it, and reads back struct layouts and
constant values. It is clever, and it works.

It also **puts a C toolchain on the load path of every system that depends on you.**

Think about what that means. A developer types the equivalent of `install this library`, and
is met with a C compilation they never asked for, for a library they have not heard of, as a
transitive dependency of the thing they actually wanted. On Linux this is usually survivable.
On Windows it has historically meant installing MSYS2 — a Unix emulation layer — before
anything at all will load.

I have come to think this is a substantial and under-discussed reason Common Lisp adoption on
Windows is worse than it should be. Not the language. Not the tooling. The fact that a
significant fraction of interesting libraries demand a C build before they will load.

So the first decision: **no groveller.**

## One: hand-written bindings, and letting the library answer

Grovel exists to answer a question — *how big is this struct, and where are its fields?* If
you can get that answer another way, you do not need it.

libuv, it turns out, anticipated this. It exports `uv_loop_size()`, `uv_handle_size()`, and
`uv_req_size()` **precisely so that bindings do not have to know its layouts.** You ask the
library how much memory to allocate; you never describe its internals. Those are functions,
callable through ordinary FFI, at runtime.

That leaves enum constants, which do have to be hardcoded. An upstream reordering would
silently change their meaning, which is exactly the kind of bug that surfaces months later in
someone else's production. So the constants are **verified at load** against
`uv_handle_type_name()` — if libuv's ordering ever changes, the system refuses to load and
says so, rather than quietly sizing a handle wrong.

No C compiler on the load path. Not for us, not for anything downstream.

## Two: no CMake, no make, no build system at all

libuv ships a `CMakeLists.txt`, and the obvious move is to shell out to CMake. That means
CMake is now a prerequisite, and we are back to asking developers to install build tooling
before anything works.

But look at what building libuv actually *is*: **37 C files, one compiler invocation.** The
source list, the `-D` defines, and the link libraries are all sitting in that CMakeLists,
plainly readable. A build system is not required to do that. It is required to do it
*generally*, for arbitrary projects, on arbitrary platforms. We need it for exactly one
project at exactly one pinned version.

So `scripts/build-libuv.lisp` — a Lisp script — fetches the pinned tarball, verifies its
SHA-256, transcribes that source list, and calls the compiler once:

```
libuv 1.52.1 (MACOS)
  sha256 verified (66d511b9e6e334c0)
  compiling 37 sources with cc
  built libuv.1.dylib (216,784 bytes)
```

Five seconds, cold, on a machine that had never done it before. No CMake, no autotools, no
make. `sbcl --script` is the only build driver in the tree, and that includes the C.

The prerequisite rule that falls out of this: **nothing beyond the platform's own
first-party toolchain.** Xcode Command Line Tools on macOS, the distribution's gcc on Linux,
MSVC on Windows. Explicitly *not* MSYS2 — even though libuv builds fine under it — because a
Unix emulation layer is one more thing to acquire before anything works, and that cost is
invisible to maintainers who are already on Unix.

## Three: integers are where silent bugs live

libuv speaks in integers. A bitmask says what changed about a file. A negative number says
what went wrong. A small enum says what kind of handle you are holding.

Integers cross boundaries silently and wrongly. A `-2` that should have been checked, an
event mask tested with the wrong bit, a handle type confused for another — none of these
announce themselves. They surface later, somewhere else, as behaviour nobody can explain.

So the layer immediately above the FFI is **Coalton**, and its entire job is to decode those
integers into algebraic data types exactly once, at the boundary. `FileEvent`. `UvErrorKind`.
`DirentKind`. Above that line, nothing in the system reasons about a `-2`.

This is a small amount of code doing a specific job, and it generalises past libuv. Every
capability that touches the outside world crosses the same kind of boundary: a logger's
keywords, a CSV parser's characters, a database's wire protocol. **Decode once, at the edge,
into types — then never think about the untyped form again.**

One rule keeps it honest: *decode once per operation, not once per byte.* An error code is
decided once per failed syscall. A parse state transition happens once per character. The
first belongs in the typed layer; the second has to earn its place with a measurement.

## What we deliberately did not do

`uv_queue_work` is not bound, and will not be.

libuv runs the *work* function on a genuinely foreign thread from its internal pool. Our
callbacks only ever re-enter Lisp on stacks that SBCL created — that is what makes the whole
binding safe, and it is why no out-of-process design was needed here. Binding
`uv_queue_work` would break the invariant for a capability we do not need, because SBCL has
real threads and we can use them.

A binding that implies more coverage than it has is worse than one that says no.

## What it does not do yet

At the time of writing:

- **Streams are not built.** No TCP, no pipes. That is the piece an HTTP server needs, and
  it is the next milestone.
- **Windows is unproven.** The build script carries a Windows source list transcribed from
  the same CMakeLists, and it has never been executed. Saying so is not modesty; it is the
  only accurate statement available.
- **Recursive directory watching is not honoured on Linux**, because inotify has no recursive
  mode. macOS and Windows honour it. The API says so rather than silently walking the tree
  and pretending.

Sixty tests pass, natively, on Linux and on macOS.

## Back to the surface

What you want from a descent into C is to come back up with something, and to leave the
hatch closed behind you. No toolchain on anyone's load path. No build system anyone has to
install. No integers loose above the waterline.

And then the part that makes it worth doing at all: an event loop, in a **live image**. A
running system with a running loop, which you can reach into and redefine while it runs, and
watch the next event take the new path.

*Mobilis in mobile.* Moving within the moving element. Verne would have understood the
appeal — although in fairness, he had a submarine.
