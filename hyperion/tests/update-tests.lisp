;;;; update-tests.lisp --- the updater's typed core (#76).
;;;;
;;;; WHAT THIS SUITE IS FOR. The updater decides whether to replace a working program on
;;;; someone else's machine. Two of its branches are security boundaries -- the refusal of
;;;; anything not strictly newer, and the refusal to treat an unknown installed version as
;;;; "current" -- and in the client this was promoted from, both lived inside a `cond' that
;;;; also reached into the network. They were correct and they were nearly untestable.
;;;;
;;;; Pulling the decision into `evaluate-candidate' is what lets the table below exist:
;;;; every branch driven from literals, no source to stand up, no network, no clock.
;;;;
;;;; THE DOWNGRADE CASES ARE THE ONES THAT MATTER. A replayed stale manifest is correctly
;;;; signed -- we signed it -- so no signature check can refuse it and only the comparison
;;;; can. `offered-older-*' and `offered-equal-*' are that refusal, and they are the tests
;;;; to be most suspicious of if this file is ever "simplified".

;;; --- Coalton-side wrappers, so CL can drive the core with plain strings ----
;;;
;;; Monomorphic and typeclass-free, which is what makes a Coalton function callable from
;;; CL. Empty string means `None' at the boundary -- these drive absence, not malformation.

(cl:defpackage #:hyperion/update/tests/fixtures
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:ver #:hyperion/update/version)
                    (#:st #:hyperion/update/state))
  (:export #:parse-render #:parses? #:compare-versions #:newer?
           #:decide #:decide-block #:decide-version #:block-detail-of
           #:schema-block-name #:schema-block-detail
           #:reinstall-detail #:mismatch-name
           #:decide-dated #:decide-block-dated #:dated-detail
           #:published-ok? #:published-order
           #:lifecycle-name #:lifecycle-version
           #:relaunch-block-name #:relaunch-detail))
(cl:in-package #:hyperion/update/tests/fixtures)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (declare parse-render (String -> String))
  (define (parse-render s)
    "Parse S and render it back canonically; the empty string when it does not parse."
    (match (ver:parse-version s)
      ((Some v) (ver:version-string v))
      ((None) "")))

  (declare parses? (String -> Boolean))
  (define (parses? s)
    "Does S parse as a version at all?"
    (match (ver:parse-version s)
      ((Some _) True)
      ((None) False)))

  (declare compare-versions (String * String -> String))
  (define (compare-versions a b)
    "lt / eq / gt, or malformed when either side is not a version."
    (match (Tuple (ver:parse-version a) (ver:parse-version b))
      ((Tuple (Some x) (Some y))
       (match (ver:version-compare x y)
         ((LT) "lt")
         ((EQ) "eq")
         ((GT) "gt")))
      (_ "malformed")))

  (declare newer? (String * String -> Boolean))
  (define (newer? candidate-version installed)
    "Is CANDIDATE-VERSION strictly newer than INSTALLED?"
    (match (Tuple (ver:parse-version candidate-version) (ver:parse-version installed))
      ((Tuple (Some c) (Some i)) (ver:version-newer? c i))
      (_ False)))

  (declare opt-version (String -> (Optional ver:Version)))
  (define (opt-version s)
    "The empty string is absence; anything else is parsed."
    (if (== s "") None (ver:parse-version s)))

  (declare candidate (String * String * Boolean * String -> st:Update-State))
  (define (candidate installed offered artifact? minimum)
    "Drive the decision from strings."
    (st:evaluate-candidate (opt-version installed) (opt-version offered)
                           artifact? (opt-version minimum) None None None))

  (declare decide (String * String * Boolean * String -> String))
  (define (decide installed offered artifact? minimum)
    "The resulting state's name."
    (st:state-name (candidate installed offered artifact? minimum)))

  (declare decide-block (String * String * Boolean * String -> String))
  (define (decide-block installed offered artifact? minimum)
    "The block reason's name, or the empty string when the state is not Blocked."
    (match (candidate installed offered artifact? minimum)
      ((st:Blocked b) (st:block-name b))
      (_ "")))

  (declare decide-version (String * String * Boolean * String -> String))
  (define (decide-version installed offered artifact? minimum)
    "The version the state is about, or the empty string when it is about none."
    (match (st:state-version (candidate installed offered artifact? minimum))
      ((Some v) (ver:version-string v))
      ((None) "")))

  ;; The schema refusal is not reachable from `evaluate-candidate' -- the shell raises it
  ;; while parsing, before any comparison exists to make -- so it is driven directly.

  (declare schema-block-name (Integer * String -> String))
  (define (schema-block-name declared url)
    (st:block-name (st:Unsupported-Schema declared url)))

  (declare schema-block-detail (Integer * String -> String))
  (define (schema-block-detail declared url)
    (match (st:block-detail (st:Unsupported-Schema declared url))
      ((Some d) d)
      ((None) "")))

  ;; The dated variants drive the SECOND half of anti-rollback. Empty string means the
  ;; timestamp is absent, which is the pre-timestamp-build case and must not block.

  (declare opt-published (String -> (Optional st:Published)))
  (define (opt-published s)
    (if (== s "") None (st:parse-published s)))

  (declare published-ok? (String -> Boolean))
  (define (published-ok? s)
    "Does S survive the shape check?"
    (match (st:parse-published s)
      ((Some _) True)
      ((None) False)))

  (declare published-order (String * String -> String))
  (define (published-order a b)
    "predates / not-predates for two ACCEPTED timestamps; refused when either is rejected."
    (match (Tuple (st:parse-published a) (st:parse-published b))
      ((Tuple (Some x) (Some y))
       (if (st:published-predates? x y) "predates" "not-predates"))
      (_ "refused")))

  (declare dated (String * String * String * String -> st:Update-State))
  (define (dated installed offered offered-published installed-published)
    (st:evaluate-candidate (opt-version installed) (opt-version offered)
                           True None None
                           (opt-published offered-published)
                           (opt-published installed-published)))

  (declare decide-dated (String * String * String * String -> String))
  (define (decide-dated installed offered offered-published installed-published)
    (st:state-name (dated installed offered offered-published installed-published)))

  (declare decide-block-dated (String * String * String * String -> String))
  (define (decide-block-dated installed offered offered-published installed-published)
    (match (dated installed offered offered-published installed-published)
      ((st:Blocked b) (st:block-name b))
      (_ "")))

  (declare dated-detail (String * String * String * String -> String))
  (define (dated-detail installed offered offered-published installed-published)
    (match (dated installed offered offered-published installed-published)
      ((st:Blocked b)
       (match (st:block-detail b)
         ((Some d) d)
         ((None) "")))
      (_ "")))

  ;; The apply-lifecycle states are downstream of applying, so `evaluate-candidate' cannot
  ;; produce them. Built directly, which is also honest about their status: they are
  ;; section 7 requirements with no code path setting them until the apply path lands.

  (declare lifecycle-state (String * String -> st:Update-State))
  (define (lifecycle-state which v)
    (match (ver:parse-version v)
      ((None) st:Up-To-Date)
      ((Some parsed)
       (if (== which "staged")
           (st:Staged parsed)
           (if (== which "applying")
               (st:Applying parsed)
               (if (== which "pending-confirmation")
                   (st:Pending-Confirmation parsed)
                   (if (== which "unreachable")
                       st:Source-Unreachable
                       st:Up-To-Date)))))))

  (declare lifecycle-name (String * String -> String))
  (define (lifecycle-name which v)
    (st:state-name (lifecycle-state which v)))

  (declare lifecycle-version (String * String -> String))
  (define (lifecycle-version which v)
    (match (st:state-version (lifecycle-state which v))
      ((Some parsed) (ver:version-string parsed))
      ((None) "")))

  (declare relaunch-block-name (String -> String))
  (define (relaunch-block-name v)
    (match (ver:parse-version v)
      ((Some parsed) (st:block-name (st:Relaunch-Failed parsed)))
      ((None) "")))

  (declare relaunch-detail (String -> String))
  (define (relaunch-detail v)
    (match (ver:parse-version v)
      ((Some parsed)
       (match (st:block-detail (st:Relaunch-Failed parsed))
         ((Some d) d)
         ((None) "")))
      ((None) "")))

  (declare reinstall-detail (String * String -> String))
  (define (reinstall-detail floor url)
    "The Needs-Reinstall sentence for FLOOR, with URL (empty string meaning none)."
    (match (ver:parse-version floor)
      ((Some v)
       (match (st:block-detail (st:Needs-Reinstall v (if (== url "") None (Some url))))
         ((Some d) d)
         ((None) "")))
      ((None) "")))

  (declare mismatch-name (String -> String))
  (define (mismatch-name detail)
    (st:block-name (st:Manifest-Mismatch detail)))

  (declare block-detail-of (String * String * Boolean * String -> String))
  (define (block-detail-of installed offered artifact? minimum)
    "The block's human-readable detail, or the empty string."
    (match (candidate installed offered artifact? minimum)
      ((st:Blocked b)
       (match (st:block-detail b)
         ((Some d) d)
         ((None) "")))
      (_ ""))))

;;; --- the suite ------------------------------------------------------------

(cl:defpackage #:hyperion/update/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:fx #:hyperion/update/tests/fixtures))
  (:export #:run-tests))

(in-package #:hyperion/update/tests)

(def-suite hyperion-update
  :description "The updater's typed core: version algebra and the update decision.")

(defun run-tests () (run! 'hyperion-update))

(in-suite hyperion-update)

;;; --- parsing ---------------------------------------------------------------

(test parses-plain-versions
  (is (string= "1.2.3" (fx:parse-render "1.2.3")))
  (is (string= "0.0.0" (fx:parse-render "0.0.0")))
  (is (string= "10.20.30" (fx:parse-render "10.20.30"))))

(test parses-and-drops-leading-v
  (is (string= "1.2.3" (fx:parse-render "v1.2.3"))))

(test parses-prerelease-tags
  (is (string= "1.2.3-beta.1" (fx:parse-render "1.2.3-beta.1")))
  ;; The FIRST hyphen splits, so a tag may contain its own.
  (is (string= "1.0.0-rc-2" (fx:parse-render "1.0.0-rc-2"))))

(test refuses-malformed-versions
  ;; Each of these would be accepted by a looser parser, and each would then be
  ;; compared as if it were a version.
  (dolist (bad (list "" "1" "1.2" "1.2.3.4" "1.2.x" "a.b.c" "1.2.3-" "-1.2.3" "1..3"))
    (is (string= "" (fx:parse-render bad))
        "expected ~S to be refused, but it parsed" bad)))

(test refuses-trailing-junk-that-parse-int-would-tolerate
  ;; parse-int is :junk-allowed, so "3nonsense" reads as 3. Without the digit check
  ;; this parses as 1.2.3 and a version that is not one gets treated as one that is.
  (is (string= "" (fx:parse-render "1.2.3nonsense")))
  (is (string= "" (fx:parse-render "1.2.+3")))
  (is (string= "" (fx:parse-render "1.2. 3"))))

;;; --- ordering --------------------------------------------------------------

(test orders-by-component-not-as-text
  ;; The case a string comparison gets wrong: "1.10.0" sorts before "1.9.0" as text.
  (is (string= "gt" (fx:compare-versions "1.10.0" "1.9.0")))
  (is (string= "lt" (fx:compare-versions "1.9.0" "1.10.0")))
  (is (string= "gt" (fx:compare-versions "2.0.0" "1.99.99")))
  (is (string= "gt" (fx:compare-versions "1.2.4" "1.2.3")))
  (is (string= "eq" (fx:compare-versions "1.2.3" "1.2.3"))))

(test prerelease-precedes-its-own-release
  (is (string= "lt" (fx:compare-versions "1.2.0-beta.1" "1.2.0")))
  (is (string= "gt" (fx:compare-versions "1.2.0" "1.2.0-beta.1")))
  (is (string= "eq" (fx:compare-versions "1.2.0-beta.1" "1.2.0-beta.1")))
  ;; A prerelease of a HIGHER version still beats a lower release.
  (is (string= "gt" (fx:compare-versions "1.3.0-alpha" "1.2.9"))))

(test newer-is-strict
  (is-true (fx:newer? "1.2.4" "1.2.3"))
  (is-false (fx:newer? "1.2.3" "1.2.3"))
  (is-false (fx:newer? "1.2.2" "1.2.3")))

;;; --- the decision ----------------------------------------------------------

(test offers-a-newer-build
  (is (string= "available" (fx:decide "1.2.3" "1.3.0" t "")))
  (is (string= "1.3.0" (fx:decide-version "1.2.3" "1.3.0" t ""))))

(test offered-equal-is-up-to-date
  ;; Re-applying the installed version is not an update; it is the replay we refuse.
  (is (string= "up-to-date" (fx:decide "1.2.3" "1.2.3" t ""))))

(test offered-older-is-up-to-date-not-an-update
  ;; THE DOWNGRADE REFUSAL. A stale manifest is correctly signed, so only this stops it.
  (is (string= "up-to-date" (fx:decide "1.2.3" "1.1.0" t "")))
  (is (string= "up-to-date" (fx:decide "2.0.0" "1.9.9" t ""))))

(test no-manifest-is-up-to-date
  ;; The honest answer for a working-tree build with the default source.
  (is (string= "up-to-date" (fx:decide "1.2.3" "" t ""))))

(test unknown-installed-version-blocks
  ;; Never "current". An updater that reads "I do not know what I am" as "I am current"
  ;; never offers the fix that matters.
  (is (string= "blocked" (fx:decide "" "1.3.0" t "")))
  (is (string= "unknown-version" (fx:decide-block "" "1.3.0" t "")))
  ;; And it blocks even with nothing on offer -- there is still nothing to compare.
  (is (string= "blocked" (fx:decide "" "" t ""))))

(test no-artifact-for-this-platform-is-its-own-state
  ;; The split this promotion introduced. The original reported "up-to-date" here, which
  ;; is the silent shape of the #206 failure: a client that cannot find its own row says
  ;; nothing is available, forever, with no error and no log line.
  (is (string= "no-artifact" (fx:decide "1.2.3" "1.3.0" nil "")))
  ;; ...and only when something newer actually exists. Nothing newer is still up-to-date.
  (is (string= "up-to-date" (fx:decide "1.2.3" "1.2.3" nil ""))))

(test below-minimum-version-needs-a-reinstall
  (is (string= "blocked" (fx:decide "1.0.0" "3.0.0" t "2.0.0")))
  (is (string= "needs-reinstall" (fx:decide-block "1.0.0" "3.0.0" t "2.0.0")))
  (is (search "2.0.0" (fx:block-detail-of "1.0.0" "3.0.0" t "2.0.0"))))

(test at-or-above-minimum-updates-normally
  (is (string= "available" (fx:decide "2.0.0" "3.0.0" t "2.0.0")))
  (is (string= "available" (fx:decide "2.1.0" "3.0.0" t "2.0.0"))))

(test no-artifact-outranks-the-minimum-check
  ;; With nothing built for this machine there is nothing to install and nothing to
  ;; reinstall either, so "not covered yet" is the accurate report.
  (is (string= "no-artifact" (fx:decide "1.0.0" "3.0.0" nil "2.0.0"))))

(test every-state-name-is-distinct-and-lower-case
  ;; A misspelt or duplicated name reaches a `case' in the shell that silently never
  ;; matches -- the same class of invisible failure as the platform-key mismatch.
  (let ((names (list (fx:decide "1.2.3" "1.3.0" t "")        ; available
                     (fx:decide "1.2.3" "1.2.3" t "")        ; up-to-date
                     (fx:decide "1.2.3" "1.3.0" nil "")      ; no-artifact
                     (fx:decide "" "1.3.0" t ""))))          ; blocked
    (is (= 4 (length (remove-duplicates names :test #'string=))))
    (dolist (n names)
      (is (string= n (string-downcase n))))))

;;; --- the schema refusal ----------------------------------------------------

(test unsupported-schema-is-its-own-reason
  ;; Not folded into malformed-manifest: a manifest from the future is well-formed and
  ;; correctly signed. The client simply cannot read it.
  (is (string= "unsupported-schema" (fx:schema-block-name 2 "https://example.test/dl"))))

(test unsupported-schema-carries-somewhere-to-click
  ;; THE ONE FAILURE AN UPDATER CANNOT FIX BY UPDATING. It recurs on every check until a
  ;; human acts, so the message has to name the schema AND carry the permanent download
  ;; URL -- which is what #75's "permanent download URL, distinct from the update channel"
  ;; requirement is actually for.
  (let ((detail (fx:schema-block-detail 7 "https://example.test/App-Setup.exe")))
    (is (search "7" detail))
    (is (search "https://example.test/App-Setup.exe" detail))))

(test schema-refusal-is-distinct-from-the-other-block-reasons
  (let ((names (list (fx:schema-block-name 2 "https://example.test/dl")
                     (fx:decide-block "" "1.3.0" t "")                 ; unknown-version
                     (fx:decide-block "1.0.0" "3.0.0" t "2.0.0"))))    ; needs-reinstall
    (is (= 3 (length (remove-duplicates names :test #'string=))))))

;;; --- the reinstall floor, and manifest substitution -------------------------

(test reinstall-refusal-links-the-installer
  ;; The design's wording is "says so plainly and links the installer". A floor the user
  ;; cannot act on leaves them stuck on an old build with no route forward -- the same
  ;; failure shape as an unsupported schema, so it gets the same escape hatch.
  (let ((detail (fx:reinstall-detail "2.0.0" "https://example.test/App-Setup.exe")))
    (is (search "2.0.0" detail))
    (is (search "https://example.test/App-Setup.exe" detail))))

(test reinstall-refusal-still-says-something-without-a-url
  ;; A manifest need not carry an installer link. The floor must still be reported.
  (let ((detail (fx:reinstall-detail "2.0.0" "")))
    (is (search "2.0.0" detail))
    (is (not (search "http" detail)))))

(test manifest-mismatch-is-its-own-reason
  ;; A manifest for another product, or a channel nobody asked for, is a substitution --
  ;; correctly signed and still not addressed to us. In the promoted client `product' and
  ;; `channel' had zero read sites, so nothing would have noticed.
  (is (string= "manifest-mismatch" (fx:mismatch-name "product is other-app, expected this-app"))))

(test every-block-reason-name-is-distinct
  ;; Six reasons, six names. A duplicate reaches a `case' in the shell that silently never
  ;; matches -- the invisible-failure shape this module keeps designing against.
  (let ((names (list (fx:decide-block "" "1.3.0" t "")                ; unknown-version
                     (fx:decide-block "1.0.0" "3.0.0" t "2.0.0")      ; needs-reinstall
                     (fx:schema-block-name 2 "https://example.test/dl")
                     (fx:mismatch-name "wrong product"))))
    (is (= 4 (length (remove-duplicates names :test #'string=))))
    (dolist (n names)
      (is (plusp (length n))))))

;;; --- anti-rollback, second half: the published timestamp --------------------
;;;
;;; Section 2 decides BOTH halves. The version comparison alone is defeated by a channel
;;; that ever reuses or resets a version number, because version and time are independent
;;; monotonic axes -- so these are not redundant with the version tests above.

(test newer-version-published-earlier-is-refused
  ;; The case the version check cannot see: 2.0.0 really is newer than 1.0.0, but it is
  ;; dated before the running build. A correctly operated channel cannot produce this.
  (is (string= "blocked"
               (fx:decide-dated "1.0.0" "2.0.0"
                                "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z")))
  (is (string= "stale-manifest"
               (fx:decide-block-dated "1.0.0" "2.0.0"
                                      "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z"))))

(test newer-version-published-later-is-offered
  ;; The ordinary case: newer and more recent. Both halves agree.
  (is (string= "available"
               (fx:decide-dated "1.0.0" "2.0.0"
                                "2026-06-01T00:00:00Z" "2026-01-01T00:00:00Z"))))

(test identical-timestamps-do-not-block
  ;; Equal is not "predates". A republished manifest at the same instant is not stale.
  (is (string= "available"
               (fx:decide-dated "1.0.0" "2.0.0"
                                "2026-06-01T00:00:00Z" "2026-06-01T00:00:00Z"))))

(test a-missing-timestamp-never-blocks
  ;; A build that predates the timestamp check, or a manifest omitting the field, must
  ;; still be able to update. Making absence fatal is a denial-of-update we inflict on
  ;; ourselves -- the same failure mode the schema gate has to avoid.
  (is (string= "available" (fx:decide-dated "1.0.0" "2.0.0" "" "2026-06-01T00:00:00Z")))
  (is (string= "available" (fx:decide-dated "1.0.0" "2.0.0" "2026-01-01T00:00:00Z" "")))
  (is (string= "available" (fx:decide-dated "1.0.0" "2.0.0" "" ""))))

(test the-timestamp-check-runs-after-the-version-check
  ;; An OLDER version with an older timestamp is up-to-date, not stale-manifest: the
  ;; version half already answered, and the timestamp half only has meaning for a manifest
  ;; that claims to be newer. Getting this order wrong turns the common developer case --
  ;; a local build ahead of the channel -- into a permanent security-shaped alarm.
  (is (string= "up-to-date"
               (fx:decide-dated "2.0.0" "1.0.0"
                                "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z"))))

(test stale-manifest-detail-names-both-instants
  (let ((detail (fx:dated-detail "1.0.0" "2.0.0"
                                 "2026-01-01T00:00:00Z" "2026-06-01T00:00:00Z")))
    (is (search "2026-01-01T00:00:00Z" detail))
    (is (search "2026-06-01T00:00:00Z" detail))))

;;; --- the timestamp shape, which is the comparison's correctness condition ----
;;;
;;; `published-predates?' compares lexicographically, and that tracks chronology ONLY for
;;; a fixed-width spelling. These tests exist because the two spellings that break it are
;;; both valid ISO-8601, and both break it toward a FALSE NEGATIVE -- a stale manifest
;;; that is not refused. A permissive date parser would accept them and hand them through.

(test accepts-exactly-the-specified-spelling
  (is-true (fx:published-ok? "2026-07-26T14:02:11Z"))
  (is-true (fx:published-ok? "2026-01-01T00:00:00Z")))

(test refuses-fractional-seconds
  ;; The dangerous one. "…11.500Z" sorts BEFORE "…11Z" (#x2E < #x5A) while naming the
  ;; LATER instant, so an installed build carrying a fraction makes a genuinely stale
  ;; manifest compare as newer and pass.
  (is-false (fx:published-ok? "2026-07-26T14:02:11.500Z")))

(test refuses-a-numeric-offset
  ;; Same class: "+00:00" sorts before every "Z" timestamp whatever instant it names.
  (is-false (fx:published-ok? "2026-07-26T14:02:11+00:00"))
  (is-false (fx:published-ok? "2026-07-26T14:02:11-05:00")))

(test refuses-other-plausible-spellings
  (dolist (bad (list ""                          ; absent is handled elsewhere, not here
                     "2026-07-26T14:02:11"       ; no zone
                     "2026-07-26 14:02:11Z"      ; space instead of T
                     "2026-07-26T14:02:11z"      ; lower-case zone
                     "26-07-26T14:02:11Z"        ; two-digit year
                     "2026-7-26T14:02:11Z"       ; unpadded month
                     "2026-07-26T14:02:11Zx"     ; trailing junk
                     "not-a-timestamp-at-all"))
    (is-false (fx:published-ok? bad)
              "expected ~S to be refused, but it was accepted" bad)))

(test the-false-negative-is-unreachable-once-the-shape-is-enforced
  ;; The exact bypass, stated as a test. Were the fractional form accepted, the offered
  ;; manifest below -- which genuinely predates the installed build -- would compare as
  ;; NOT predating it and would be applied. The shape check is what makes it unreachable.
  (is (string= "refused"
               (fx:published-order "2026-07-26T14:02:11Z" "2026-07-26T14:02:11.500Z")))
  ;; And with both in the accepted spelling, ordinary chronology holds.
  (is (string= "predates"
               (fx:published-order "2026-07-26T14:02:11Z" "2026-07-26T14:02:12Z")))
  (is (string= "not-predates"
               (fx:published-order "2026-07-26T14:02:12Z" "2026-07-26T14:02:11Z"))))

(test a-refused-timestamp-does-not-silently-become-absent
  ;; Documenting the obligation the shell inherits: `parse-published' answering None for a
  ;; malformed value looks identical to a manifest that has no timestamp, and absence
  ;; fails open. The shell must report Malformed-Manifest rather than pass None through,
  ;; or mangling the field becomes the bypass that stripping it cannot be.
  (is-false (fx:published-ok? "2026-07-26T14:02:11.500Z"))
  (is (string= "available"
               (fx:decide-dated "1.0.0" "2.0.0"
                                "2026-01-01T00:00:00Z" "2026-07-26T14:02:11.500Z"))))

(test the-generators-spelling-is-the-one-the-parser-accepts
  ;; A CANARY FOR THE PRODUCER HALF. `scripts/update-manifest.lisp' PUBLISHED-NOW emits
  ;; this exact FORMAT directive, and `parse-published' is the only thing that accepts it.
  ;; Two halves of one contract in two files is the #206 shape, and the failure mode is
  ;; the silent one: a generator that dropped a zero-pad would emit a 19-character
  ;; timestamp that every client refuses, forever, with no error at the producer.
  ;;
  ;; This is itself a COPY of that directive, so it is a canary and not a single source --
  ;; it catches the producer changing, not the two drifting in step. The real repair is
  ;; the one scripts/update-manifest.lisp already records as a debt: the script should
  ;; consume this module's schema rather than restate it. Until then, a canary beats
  ;; nothing, and this comment is here so nobody mistakes it for the fix.
  (let ((emitted (multiple-value-bind (s m h day month year)
                     (decode-universal-time (get-universal-time) 0)
                   (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
                           year month day h m s))))
    (is (= 20 (length emitted))
        "the generator's spelling is ~D characters, not 20: ~S" (length emitted) emitted)
    (is-true (fx:published-ok? emitted)
             "the parser refuses what the generator emits: ~S" emitted)))

(test padding-is-what-makes-the-spelling-fixed-width
  ;; The specific way a generator breaks this: single-digit fields unpadded. Each of these
  ;; is a real instant and every one must be refused, because a variable-width timestamp
  ;; is what makes the lexicographic comparison unsound in the first place.
  (dolist (bad (list "2026-1-01T00:00:00Z"
                     "2026-01-1T00:00:00Z"
                     "2026-01-01T0:00:00Z"
                     "2026-01-01T00:0:00Z"
                     "2026-01-01T00:00:0Z"))
    (is-false (fx:published-ok? bad)
              "expected the unpadded ~S to be refused" bad)))

;;; --- the apply lifecycle (section 7) ---------------------------------------
;;;
;;; These states came out of a deliberate sweep of section 7 against the code, run before
;;; the apply path was written rather than after. Section 7 decides three things about
;;; what happens AFTER a payload verifies, and nothing here modelled any of them: that
;;; progress is unreportable once the installer has control, that the previous version is
;;; kept until the new one has started successfully once, and that a failed relaunch means
;;; roll back at next start rather than "the update failed".
;;;
;;; None of the three is reachable from `evaluate-candidate' -- it decides whether to
;;; offer, and these are all downstream of applying -- so they are driven directly, which
;;; also keeps them honest about being requirements rather than tested behaviour.

(test the-apply-lifecycle-has-a-state-for-each-decided-step
  (is (string= "applying" (fx:lifecycle-name "applying" "1.3.0")))
  (is (string= "pending-confirmation" (fx:lifecycle-name "pending-confirmation" "1.3.0"))))

(test lifecycle-states-carry-the-version-they-are-about
  ;; The UI says "installing 1.3.0", and the confirmation step needs to know which build
  ;; it is confirming in order to decide the previous one may be deleted.
  (is (string= "1.3.0" (fx:lifecycle-version "applying" "1.3.0")))
  (is (string= "1.3.0" (fx:lifecycle-version "pending-confirmation" "1.3.0"))))

(test relaunch-failure-says-a-rollback-is-coming-not-that-it-failed
  ;; Section 7's wording is "treat relaunch failed as roll back at next start". The
  ;; distinction matters to the person reading it: they are about to be running an older
  ;; build than they asked for, deliberately, and finding that out later is worse.
  (is (string= "relaunch-failed" (fx:relaunch-block-name "1.3.0")))
  (let ((detail (fx:relaunch-detail "1.3.0")))
    (is (search "1.3.0" detail))
    (is (search "previous version" detail))))

(test every-state-name-across-the-whole-lifecycle-is-distinct
  ;; Eight states now, and the shell dispatches on these strings. A duplicate reaches a
  ;; `case' that silently never matches.
  (let ((names (list (fx:decide "1.2.3" "1.3.0" t "")        ; available
                     (fx:decide "1.2.3" "1.2.3" t "")        ; up-to-date
                     (fx:decide "1.2.3" "1.3.0" nil "")      ; no-artifact
                     (fx:decide "" "1.3.0" t "")             ; blocked
                     (fx:lifecycle-name "staged" "1.3.0")
                     (fx:lifecycle-name "applying" "1.3.0")
                     (fx:lifecycle-name "pending-confirmation" "1.3.0")
                     (fx:lifecycle-name "unreachable" "1.3.0"))))
    (is (= 8 (length (remove-duplicates names :test #'string=))))))
