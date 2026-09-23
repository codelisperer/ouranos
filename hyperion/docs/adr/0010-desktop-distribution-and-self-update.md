# ADR-0010 — Desktop distribution & self-update: signed manifest, stage-and-swap, native-runner CI

**Status:** Provisional — 2026-07-26 (accepted direction; design in
[`desktop-distribution-design.md`](../desktop-distribution-design.md), M1 unbuilt)

## Context

[ADR-0008](0008-desktop-shell-cl-native-webview.md) settled the desktop *shell* and named
auto-update in one line ("Ed25519 self-updater … or FFI to WinSparkle/Sparkle"). That line
hides the decisions a shipping app actually needs: who hosts artifacts, what the client
trusts, how a running binary replaces itself on three OSes, and how the artifacts get built
at all.

The forcing question was raised as: *SBCL cannot cross-compile — `save-lisp-and-die` dumps
an image for the host platform only — so must every release be hand-built by a developer on
each OS?* If true, a self-updating app is impractical: releases would be irregular, and
irregular releases make the updater pointless.

The target pattern is the one proven in the author's Tauri app (AiTP): signed artifacts,
a tag-driven pipeline, and an app that notices a new version and installs it in one click.

## Decision

1. **Native-runner CI matrix; never cross-compile.** A tagged commit builds on
   `ubuntu-22.04`, `windows-2022` and `macos-14` (arm64), each producing its own bundle and
   installer. This is what Tauri and Electron do too. The SBCL constraint is real but costs
   nothing here.
2. **A signed manifest is the contract.** One JSON document per channel at a permanent URL,
   `schema`-versioned, listing per-platform `payload` (updater) and `installer` (human)
   with size, SHA-256 and signature.
3. **Ed25519 over both artifact and manifest** (Ironclad), verified against a public key
   shipped inside the bundle. Artifact signing defends against a compromised host; manifest
   signing defends against a substituted manifest pinning users to a vulnerable version. The
   client refuses versions ≤ installed (anti-rollback).
4. **Update sources are a neutral protocol with two backends from day one** — GitHub
   Releases (~~`/releases/latest/download/`~~, zero infrastructure) and S3 (private products,
   permanent human link). An app names one or a list.

   **Corrected 2026-09-16 from inside the implementation (#332).** The URL shape is wrong;
   the decision is not. `/releases/latest/download/` is a permanent URL only for a
   repository holding **one** product, because `latest` resolves per *repository*. The
   release repo holds every desktop app in the tree, so the most recently published one
   owns `latest` and every other client asks it for a manifest that is not there. It gets
   a 404 and reads it correctly as "nothing published on this channel" — so updates stop
   **silently**, for every product but one.

   The shape that holds is a per-app, per-channel pointer release, `<app>-<channel>`,
   whose assets are replaced on each publish, beside the immutable `<app>-v<version>`
   release the manifest's payloads name. See design section 5's amendment.

   Two things this decision did not say, both found by building it. GitHub Releases is
   **public repositories only** — a private repo serves assets only to an authenticated
   request, and an installed app cannot hold a token — so a private product needs a
   separate public release repo, which is not a workaround but the reason that repo
   exists. And S3 is still **not wired**; the client reads it, nothing writes it.
5. **Per-user install locations.** `%LOCALAPPDATA%\Programs`, `~/Applications`,
   `~/.local/lib` — so the app can rewrite itself with no elevation. A per-machine install
   is detected and reported as a *state* (`NotWritable`), not a failure.
6. **One artifact per platform, and the manifest names its `format`.** Windows ships an
   NSIS installer that is *also* the update payload (run `/S`, the app exits first, the
   installer relaunches it); Linux ships an AppImage that is both; only macOS splits — a
   `.dmg` for humans, a `.app.tar.gz` for the updater. **The user never extracts an
   archive, and no archive library is needed** (`tar` is stock on macOS).
7. **Stage, verify, then apply; keep the old version.** Never write into the live bundle;
   never verify after applying. macOS swaps the whole `.app` (preserving its signature)
   after stripping the quarantine xattr; Linux renames the new AppImage over the old. The
   rename-the-running-exe dance ADR-0008 anticipated survives as the *fallback* for a
   portable Windows install and as the rollback path.
8. **The update UI is HTMX, served by the app itself** — generic components under
   `/_hyperion/update/`, progress streamed over SSE via `hyperion/channel`. No JS bridge,
   because the app is already an HTTP server.
9. **Typed core, effectful shell.** Version algebra and the `UpdateState` machine in
   Coalton; fetch/verify/stage/swap in CL (ADR-0002).
10. **OS code-signing is scheduled, not skipped.** M1 ships Ed25519 update integrity only,
   accepting SmartScreen/Gatekeeper first-install warnings; M2 adds Azure Trusted Signing
   (Windows) and Developer ID + notarization (macOS) with the exact steps, secrets and
   costs written down now.
11. **Layering:** `hyperion/update` is the library capability; `cons desktop` scaffolds and
    drives builds/publishing; the app's own repo holds keys, channel URLs and identity.

## Consequences

- **Releases become routine** — tag, wait, users get it — which is the precondition for
  maintaining a desktop app at all.
- **We own the updater.** Roughly what ADR-0008 predicted: this is Tauri's non-rendering
  glue, reimplemented. The mitigating surprise is that our payload is *two files*, so
  stage-and-swap is far simpler here than for a framework directory.
- **One new dependency:** `ironclad` (Ed25519). `dexador` is already in the tree, and
  decision 6 means no archive library at all.
- **A lost signing key strands every installed app** — it is the project's most valuable
  secret, and key rotation must be a supported, tested release path, not a fire drill.
- **macOS reproducibility is weaker than the other two.** Upstream SBCL publishes no macOS
  binaries (verified against the 2.6.6 release: Linux tarball and Windows MSIs only), so
  macOS builds use Homebrew's SBCL and cannot honour the version pin. Recorded in
  `versions.env`.
- **Installers are in M1** (NSIS, `create-dmg`, `linuxdeploy`) rather than deferred, for a
  reason that only appears when you work backwards from the swap mechanics: **the installer
  decides the install location the updater depends on**. A first install that requires
  unzipping to a specific directory is not a product. Because the installer doubles as the
  update payload on Windows and Linux, this adds far less CI surface than it appears to.

## Alternatives considered

- **Sparkle / WinSparkle via FFI.** Mature and battle-tested, but two more C dependencies,
  two different manifest formats (appcast XML), no Linux story, and an in-process bridge we
  deliberately avoided in ADR-0008. Rejected: our payload is two files; the value they add
  is mostly UI we get free from HTMX.
- **Package managers only** (winget / Homebrew / apt). Zero updater code, but release
  latency is the manager's, coverage is partial, and the app cannot tell the user anything.
  Kept as a *complement*: a package-managed install reports `NotWritable` and defers.
- **In-place binary patching (bsdiff deltas).** Meaningful bandwidth saving on a ~40 MB
  image, but it complicates verification and rollback. Deferred to M4, behind a size measurement.
- **A privileged updater service** (Chrome's Omaha model) so per-machine installs can
  self-update. Rejected for M1: a background service on three OSes is a large attack surface
  for a case per-user installs avoid entirely.
- **Building releases by hand on dev machines** — the premise this ADR rejects. It makes
  release frequency a function of developer availability, and guarantees the three OSes
  drift apart.
