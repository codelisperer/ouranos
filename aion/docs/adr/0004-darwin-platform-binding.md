# ADR-0004 — The macOS platform binding: aion/darwin, over CoreFoundation and Security

**Status:** Provisional — 2026-09-28. Follows the placement rule in
[ADR-0002](0002-libuv-integration-strategy.md) §3 and the pattern of
[ADR-0003](0003-windows-platform-binding.md). First consumer: the Keychain backend of
`hades/credentials` (#357).

## Context

`hades/credentials` stores an app's secrets in the operating system's own store. On Windows
that is Credential Manager, reached through `aion/windows`. On macOS it is the Keychain,
reached through Security.framework, whose calls take and return CoreFoundation objects
(CFString, CFData, CFDictionary) and report failure as an `OSStatus` integer. Any later macOS
work (notifications, the pasteboard, launch services) needs the same CoreFoundation handling.
If each consumer bound it for itself, each would carry its own copy of the rules below, and a
mistake in one copy would leak memory or crash the image.

## Decision

**1. One macOS binding, in aion, named `aion/darwin`.** `darwin` because SBCL pushes
`:darwin` on macOS, so every reader conditional in the tree already reads `#+darwin`. It
holds what every macOS framework call needs: CoreFoundation strings, data and dictionaries,
ownership, `OSStatus` as a condition, and access to exported framework constants such as
`kSecClassGenericPassword`. It also holds the raw `defcfun`s a consumer calls, in
`aion/darwin/ffi`. It does not hold anything specific to one consumer: the Keychain query a
credential store builds belongs in `hades/credentials`, not here.

**2. cffi only, no new dependency and no C.** CoreFoundation and Security ship with every
macOS, at fixed paths under `/System/Library/Frameworks`, so there is nothing to build, pin
or carry into an app bundle. `cffi` is already in the tree. `aion/darwin` is registered in
`scripts/platform-packages.lisp` under `:darwin` as `:required`, so the macOS leg loads it.

**3. Ownership follows CoreFoundation's rule, and `with-cf` enforces it.** A function with
`Create` or `Copy` in its name returns an object the caller owns and must release exactly
once; a `Get` function returns one the caller must not release. Every `make-cf-*` function
here is a `Create`. `with-cf` binds owned objects and releases each one that is not NULL on
every exit from its body, including a non-local exit through `throw`, `return-from` or a
signalled error, so an error between a `Create` and its release cannot leak. A value added to
a dictionary is retained by the dictionary, so the caller still releases its own reference.
Framework constants from `cf-constant` are owned by the framework and are never released.
`cf-release` ignores NULL, because `CFRelease` itself crashes on it.

**4. A failing `OSStatus` becomes an `osstatus-error`.** `check-osstatus` returns the status
when it is `errSecSuccess` (0) and otherwise signals `osstatus-error`, a `darwin-error`
carrying the code, the operation that failed, and macOS's own wording from
`SecCopyErrorMessageString`. No table of codes is kept here. A consumer that treats a
particular code as an ordinary outcome, such as `errSecItemNotFound` (-25300) meaning "no
such item", compares the code before calling `check-osstatus`; the constants it needs are
exported from `aion/darwin/ffi`.

**5. Secret bytes are zeroed where Lisp controls them.** `make-cf-data` zeroes the foreign
buffer the bytes pass through before it is freed. The copy CoreFoundation keeps inside the
CFData is not zeroed when it is released; that is outside what this binding can reach.

## Consequences

- The tests in `aion/darwin/tests` make no Keychain calls: they round-trip strings (including
  non-ASCII and empty), data and dictionaries, check that `with-cf` releases on a non-local
  exit, decode a real `OSStatus`, and read a framework constant.
- A consumer gets macOS support by depending on `aion/darwin` under
  `(:feature :darwin "aion/darwin")`, the same way Windows consumers depend on
  `aion/windows`.

## Alternatives considered

- **Bind CoreFoundation inside `hades/credentials`.** Rejected: the next macOS consumer would
  copy it, and ADR-0002 §3 puts bindings for the platform's own API in aion.
- **Call the `security` command-line tool.** Rejected: the secret would pass through a
  process argument or a pipe, and a failure would arrive as text to parse instead of a code.
- **An Objective-C bridge.** Not needed: the Keychain API is plain C over CoreFoundation.

## Provenance

The first version of the `with-cf` release test used a short CFString, and it still passed
with the release removed from `with-cf`. macOS stores a short ASCII CFString as a tagged
pointer, and its retain count does not change: measured on macOS 26 (arm64), "count me" came
back at address `#x972AA0EB28F2009A` with a count of 9223372036854775807 both before and after
a `CFRetain`, while a 64-byte CFData went from 1 to 2. The test now counts references on that
CFData, and the same control fails it.
