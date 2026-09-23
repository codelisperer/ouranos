;;;; packages.lisp --- hyperion/update: the desktop self-updater (#76).
;;;;
;;;; PROMOTED, NOT WRITTEN FRESH. The client half of this module existed first inside a
;;;; consuming application that ships it to real users, and its shape is that client's
;;;; shape. The invariants below are not deductions from the design doc -- they are what a
;;;; production updater was found to need, and several were learned the expensive way.
;;;; ADR-0010 and `docs/desktop-distribution-design.md' record the decisions; this records
;;;; only what the code needs a reader to know.
;;;;
;;;; THE SPLIT. Version algebra and the state machine are Coalton -- pure, total, testable
;;;; with no network and no filesystem. Fetching, verifying, staging and swapping are CL,
;;;; because every one of them is IO. That is ADR-0002 applied, and it is load-bearing
;;;; here: the anti-rollback comparison is the security boundary, and it is the one part
;;;; that can be exhaustively tested without mocking anything at all.
;;;;
;;;; VERIFY THE SIGNATURE BEFORE READING ANYTHING THE DOCUMENT SAYS ABOUT ITSELF --
;;;; the schema number included. The ordering is not fussiness. If the schema gate runs
;;;; first, anyone who can serve us bytes triggers the refusal path with unsigned garbage
;;;; and the client stops updating: a denial-of-update, which against a security fix IS
;;;; the attack, and it costs the attacker nothing. Parse, then verify, THEN interpret.
;;;; The manifest is parsed, not trusted: nothing in it has meaning until the signature
;;;; over its exact bytes has been checked.
;;;;
;;;; WHY THE SCHEMA LIVES HERE. `scripts/update-manifest.lisp' generates the manifest and
;;;; names its fields; this parses it and names them again. Two copies of one contract is
;;;; exactly the shape of #206, where a platform-key mismatch made a client report itself
;;;; up to date forever -- a failure that is silent, permanent, and only visible at the
;;;; user. That script records the debt explicitly and names this module as the place it
;;;; is repaid: the field names belong in ONE place, and it is this one.

(cl:defpackage #:hyperion/update/version
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:str #:coalton-library/string)
                    (#:chr #:coalton-library/char)
                    (#:iter #:coalton-library/iterator))
  (:documentation
   "Version algebra: parse, render, and above all COMPARE.

    The comparison is the reason this is typed. `apply-update' refuses anything not
    strictly newer than what is installed, and that refusal is the client's whole defence
    against a downgrade attack -- a replayed stale manifest, correctly signed, offering a
    real past release with a known hole in it. The server is authoritative about what is
    CURRENT; the client is authoritative about what it HAS. Only the client can make this
    particular refusal, so the comparison it turns on is worth a type and an exhaustive
    test suite rather than a hand-rolled string compare at a call site.")
  (:export
   #:Version #:version-major #:version-minor #:version-patch #:version-prerelease
   #:parse-version #:valid-version? #:version-string #:version-compare
   #:version-newer? #:version-same?))

(cl:defpackage #:hyperion/update/state
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:ver #:hyperion/update/version)
                    (#:str #:coalton-library/string)
                    (#:chr #:coalton-library/char)
                    (#:iter #:coalton-library/iterator)
                    (#:lst #:coalton-library/list))
  (:documentation
   "What an update attempt IS at any moment, and what went wrong when it did.

    THE VARIANT SET IS THE PROMOTION'S ONE REAL DESIGN CHANGE, and it was asked for by the
    session whose client this came from. The original collapsed three distinct outcomes
    into a single `up-to-date': no manifest at all, a manifest offering nothing newer, and
    a manifest with no artifact for THIS platform. A caller could not tell them apart.

    The third is the one that matters, and it is split out here as `No-Artifact'. \"No
    build for your platform yet\" is a different sentence to a user than \"you are
    current\" -- a platform can join the release matrix a release late, which is normal
    and temporary. It is also the exact shape of the silent failure #206 produced: a
    client that cannot find its own row reports itself up to date forever, with no error,
    no log line, and no user who thinks to report that something did not happen. A state
    that can only be reached by a real absence is how that stays visible.

    The first is deliberately NOT split. For a build running from a working tree the
    default source honestly answers \"no channel\", and \"there is nothing to offer you\"
    is the same actionable state as \"you are current\". `No-Artifact' differs precisely
    because a channel DOES exist and does have something newer -- that is information.

    TWO OUTCOMES ARE QUIET AND FOUR ARE LOUD. `Up-To-Date', `No-Artifact' and
    `Source-Unreachable' are ordinary; a UI may render nothing at all. A failed check especially
    is background noise -- the network is down, the user is on a plane -- and an updater
    that interrupts someone's work to report that it could not reach a server has
    misjudged whose problem that is. `Blocked' is the only variant that owes the user a
    sentence, which is why every reason it carries has one.

    `Not-Writable' IS A STATE, NOT AN EXCEPTION. An application installed per-machine by
    an administrator cannot rewrite itself without elevation, and the right response is
    \"ask whoever installed this\" -- not a stack trace at a user with no way to act on it.
    Model it as an error and every consumer re-invents the same state, badly. NOTE for
    whoever wires the elevation check: in the client this was promoted from, the
    corresponding variant was rendered by the UI and set by NO code path. It is a
    requirement here, not tested behaviour.")
  (:export
   #:Update-State #:Up-To-Date #:No-Artifact #:Source-Unreachable
   #:Available #:Staged #:Applying #:Pending-Confirmation #:Blocked
   #:Update-Block #:Bad-Signature #:Would-Downgrade #:Needs-Reinstall
   #:Not-Writable #:Unknown-Version #:Malformed-Manifest #:Unsupported-Schema #:Manifest-Mismatch #:Stale-Manifest #:Relaunch-Failed
   #:Published #:parse-published #:published-string #:published-predates?
   #:state-name #:block-name #:block-detail #:state-version
   #:valid-published? #:decide-from-text #:state-version-text
   #:state-block-name #:state-block-detail
   #:evaluate-candidate))

;;; The effectful shell. CL, because every line of it is IO: HTTP, Ed25519, JSON, the
;;; filesystem and eventually a process launch. The decision it wraps is the typed core
;;; above, which is what lets the security-critical comparison be tested without any of this.
(cl:defpackage #:hyperion/update
  (:use #:cl)
  (:local-nicknames (#:version #:hyperion/update/version)
                    (#:state #:hyperion/update/state)
                    (#:sig #:aion/signature)
                    (#:platform #:aion/platform)
                    (#:http #:aion/http-client)
                    (#:json #:com.inuoe.jzon)
                    (#:base64 #:cl-base64)
                    (#:rand #:aion/random))
  (:documentation
   "Fetch, verify and decide -- the effectful half of the desktop self-updater.

    THE ORDER IS THE DESIGN: fetch bytes, verify the bytes, then interpret. Nothing the
    manifest says about itself is read before its signature over its exact bytes has been
    checked, because a refusal path reachable with unsigned input is a denial-of-update
    that costs an attacker nothing.

    Applying is NOT built. `apply-update' refuses, per platform and for per-platform
    reasons, and the refusal is the honest state rather than a TODO that happens to run: an
    updater that fetches and executes a binary without verifying it is a remote-code-execution
    vector shipped enabled to every customer.")
  (:export
   ;; what the application supplies
   #:*installed-version* #:*installed-published* #:*public-key* #:*update-source*
   #:*download-url*
   #:*before-apply* #:*app-name* #:*install-directory* #:*launch-installer* #:*exit-after-handoff*
   ;; the source protocol and its backends
   #:fetch-manifest #:fetch-artifact
   #:null-source #:http-source #:github-release-source #:s3-source #:source-base-url
   #:directory-source #:source-path
   ;; the manifest, after verification
   #:manifest #:manifest-p #:manifest-schema #:manifest-product #:manifest-channel
   #:manifest-version #:manifest-published #:manifest-notes-url
   #:manifest-minimum-version #:manifest-platforms #:manifest-platform
   #:platform-payload-url #:platform-installer-url #:platform-format
   ;; the check
   #:check-for-update #:update-status #:banner-worthy-p #:+quiet-statuses+
   ;; applying
   #:apply-update #:install-directory #:install-writable-p #:stage-payload
   #:launch-installer #:unknown-payload-format #:unknown-payload-format-name
   ;; conditions
   #:update-source-error #:update-source-error-detail
   #:update-not-implemented #:update-not-implemented-detail))
