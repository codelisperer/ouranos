---
title: "The bugs that only exist on someone else's machine"
date: 2026-07-29
status: draft
tags: [common-lisp, ci, desktop, testing, ai-assisted-development]
summary: >
  A week of shipping desktop apps in Common Lisp produced five bugs with one thing in common:
  each was invisible on a machine that had already built the project. Green CI is not evidence.
---

# The bugs that only exist on someone else's machine

Last week I got a desktop app building on three operating systems from a single tagged commit.
Continuous integration went green: Linux, macOS, Windows, each producing its own binary. The app
launched on my machine and opened a real native window.

Then I copied the Linux artifact to a different Linux box and ran it:

```
Error opening shared object "libev.so.4":
  libev.so.4: cannot open shared object file: No such file or directory.
```

Not a warning. The app simply did not start. It had never started anywhere except a machine that
had already compiled the project, and I had no way of knowing that, because every machine I owned
had compiled the project.

That was the first of five. They turned out to be the same bug wearing different clothes, and the
pattern is more useful than any of them individually.

## What we were building

Some context, briefly. I'm building a set of Common Lisp frameworks, and one of them turns a web
app into a native desktop app: a compiled Lisp image runs an HTTP server on localhost, and a tiny
native binary opens the platform's webview pointed at it — WebView2 on Windows, WKWebView on
macOS, WebKitGTK on Linux. No Electron, no Node, no Rust toolchain. Two files: the app and the
launcher.

The Lisp part matters for one reason. SBCL, the compiler, ships an application by **dumping the
running image** to an executable. That gives you a single self-contained binary, which is
wonderful — and it makes it very easy to believe the binary is more self-contained than it is.

## Bug one: self-contained Lisp is not self-contained software

A dumped image contains all of your Lisp. It does not contain the C libraries your Lisp reaches
for through its foreign-function interface, and it resolves those **by name, at load time, on the
user's machine**. My web server bound `libev` — an event-loop library — so `libev` was a hard
runtime requirement of every Linux and macOS build I produced.

Every developer machine has `libev`, because building the project installs it. No user does.

The fix was to stop needing it, which raised a question I couldn't answer from an armchair.

## Bug two: the benchmark that found a different bug than it went looking for

The event-loop server could be swapped for a thread-per-connection one that is pure Lisp — no C
dependency at all. The objection was performance: a desktop app might drive a live feed, updating
many times a second.

So I measured, using one small HTML fragment fetched repeatedly over a single connection, the way
a browser actually behaves:

| server | per request (median) |
| --- | --- |
| event loop (Woo) | **0.15 ms** |
| thread-per-connection (Hunchentoot) | **44.00 ms** |

Nearly 300× worse. Case closed, apparently — except 44 ms is a suspiciously round number. It's
almost exactly the delayed-ACK timer. So I tried the same server, the same bytes, the same
connection, with one header added:

| server | per request (median) |
| --- | --- |
| thread-per-connection, with `Content-Length` | **0.17 ms** |

The slow server was never slow. Without a length header, the response goes out chunked, and
chunked encoding's terminating zero-length chunk is a **separate small write**. Nagle's algorithm
holds that write, waiting for an acknowledgement the client won't send until it has a complete
response. Both sides wait until a timer fires.

Which means it wasn't a server problem at all. **It was a bug in my framework**, on the main
request path, costing 44 ms on every interaction over a reused connection — for every application
built on it. One header fixed it, from 44.00 ms to 0.24 ms.

Note the shape of what hid it: measure with a **fresh connection per request** and the floor
vanishes entirely. 0.6 ms, no anomaly, no clue. Browsers reuse connections. A benchmark that
doesn't is measuring a workload nobody runs.

## Bug three: the app that used the wrong copy of itself

The desktop app launches its native webview by finding the launcher binary next to itself. I
tested this repeatedly. It worked every time.

Then I copied the whole bundle to a temporary directory and ran it there. It launched the copy of
the launcher **from my source tree**, not the one sitting beside it.

The lookup asked the operating system for the running program's path, which routinely arrives with
no directory attached — just `app.exe`. Joining that with a filename produces a *relative* path,
and the runtime resolves relative paths against a working directory that, in a dumped image, was
**frozen at build time**: my project root. So the lookup silently searched the build machine's
layout, missed, and fell through to a fallback that happened to find my development copy.

On a user's machine there is no source tree. The fallback would have found nothing, and the app
would have opened no window at all — on every operating system. I had verified this feature many
times, and every verification was contaminated by a source tree sitting where a user's wouldn't
be.

## Bug four: the code path that had never run

The provisioning script installs the compiler and the package manager on a fresh machine. It
worked on all three of mine.

It had never *executed* on any of them. They already had those things installed, so it took the
"already present, skip" branch every time. The first machine to run the real code was a CI runner,
which failed five times in a row, each for a different reason:

- The compiler's official Linux binary requires a newer glibc than the distribution I'd
  deliberately chosen for maximum compatibility. My reasoning — *build on the oldest system you
  support* — was not merely wrong, it was impossible.
- On Windows, the download saved a web page instead of an installer, and the installer tool
  reported `1620`, which means "this package could not be opened" and suggests nothing about why.
- After installing the compiler, the script couldn't find it: a running process's `PATH` is a
  snapshot from when it started, so the very process that ran the installer was blind to what the
  installer had added.
- A file path passed to the compiler lost its surrounding quotes somewhere in the shell layers,
  so `C:/Users/...` was parsed as a namespace reference and the run died with `Package "C" does
  not exist`.
- And my own filename parser rejected the version string CI generates, because I'd only ever
  tested versions that looked like `0.1.0`.

Five failures, five real facts about the world. Not one of them was a reasoning error, and not one
was findable by reasoning.

## Bug five: the diagnostic that lied politely

To prevent all this, I wrote a doctor: a `--check` mode that reports what's missing and how to
install it. On a fresh Linux box it said `MISSING: SBCL`, and advised running the setup script.

The setup script had already installed SBCL, one line earlier. It goes to a per-user directory
that isn't on `PATH` in a non-login shell, and the doctor only looked at `PATH`. A new user would
have followed that advice forever.

A checker that can't see the thing it installed is worse than no checker, because it is
authoritative.

## The pattern

Every one of these hid behind an assumption that was already true where I was standing:

| what looked fine | what hid it |
| --- | --- |
| the Linux binary | dev machines have the C library users don't |
| the HTTP layer | one request per connection hides a 44 ms floor |
| finding the sibling binary | a source tree nearby satisfied the fallback |
| the provisioning script | everything it installs was already installed |
| the doctor | it only looked where the thing wasn't |

The habit worth taking away isn't "test more". It's **test where the assumption is not already
satisfied** — and that's a different, cheaper activity than exhaustive testing. You don't need
more tests; you need one machine that hasn't been prepared. A fresh container. A spare VM. A new
WSL distribution. The artifact copied somewhere it has no relatives. The connection reused instead
of reopened.

A corollary I now take seriously: **a green exit code is not evidence.** My CI was green while
producing a Linux binary that could not run on Linux. Green means "the steps I wrote completed" —
which is a claim about my script, not about my software.

There's a smaller cousin worth naming. Partway through, I updated a dependency and the build
loaded it without recompiling. My first instinct was relief: *it must already be correct*. But
"loaded without recompiling" is equally the symptom of **stale compiled artifacts being served
from a cache**. Same observation, opposite conclusions. I now have a script that proves which
version is loaded rather than inferring it — provenance *and* a behavioural probe, because
provenance alone can't see a stale cache.

## The part where AI comes in

I built all of this alongside an AI assistant, and the division of labour turned out to matter.

The assistant wrote the cross-platform plumbing fast and well — installers, CI matrices, per-OS
build scripts — the kind of work that is mostly grind and where a fast, tireless collaborator is
transformative. It was also **confidently wrong about the world** in exactly the places listed
above: which library a symbol lives in, whether a URL returns a file or a web page, what a
process's environment contains after an installer runs. Fluent, plausible, and wrong.

Two things closed that gap, and neither was better prompting.

The first was insisting on measurement. My comment on the server question was, essentially, "the
event loop *feels* like it should handle that better." That hunch was wrong about the cause and
completely right that it needed a number — and the number found a bug in my own framework instead.

The second was supplying the clean machine. The assistant cannot conjure an unprepared
environment; it works where it is. Every real defect surfaced the moment we ran the artifact
somewhere that hadn't been prepared for it. That's a human decision about *where* to look, and
it's the highest-leverage thing I did all week.

Which is a fair summary of how this collaboration goes when it goes well: it does the work, I
decide what would falsify it.
