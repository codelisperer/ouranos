;;;; state.lisp --- what an update attempt is, and the decision that produces it (Coalton).
;;;;
;;;; THE DECISION IS PURE, AND THAT IS THE POINT OF PROMOTING IT HERE. In the client this
;;;; came from, the same decision was interleaved with the fetch: one `cond' reached into
;;;; the network, the parsed manifest and the platform table at once. It was correct, but
;;;; it could only be tested by standing up a source, which means the anti-rollback branch
;;;; -- the one that refuses a downgrade attack -- was the hardest branch in the file to
;;;; exercise and the most expensive one to get wrong.
;;;;
;;;; `evaluate-candidate' takes what the shell already knows and returns the state. No IO,
;;;; total, and every branch reachable from a literal. The CL shell does the fetching and
;;;; the parsing and then asks this what it means.

(cl:in-package #:hyperion/update/state)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Published
    "A manifest's `published' timestamp: ISO-8601 UTC, e.g. \"2026-07-26T14:02:11Z\".

A NEWTYPE RATHER THAN A BARE STRING, deliberately. `evaluate-candidate' takes an installer
URL and two timestamps, all of which would otherwise be `Optional String' -- three
indistinguishable parameters in a row, where transposing two type-checks cleanly and
silently disables a security comparison. The wrapper makes that mistake impossible to write.

Compared lexicographically, which is correct ONLY because the format is fixed: ISO-8601,
UTC, `Z'-suffixed, fixed width, as section 3 specifies and `scripts/update-manifest.lisp'
emits. A local-offset or variable-width timestamp would compare wrongly, so the parser
must refuse anything that is not this shape rather than passing it through to here."
    (%Published String))

  ;; THE RAW CONSTRUCTOR IS NOT EXPORTED. `parse-published' is the only way in, because
  ;; the comparison below is only sound for one exact spelling and a value that reached
  ;; here unchecked would compare wrongly and silently.

  (declare published-string (Published -> String))
  (define (published-string p)
    "The underlying timestamp text."
    (match p ((%Published x) x)))

  (declare digits-at? (String * UFix * UFix -> Boolean))
  (define (digits-at? s start end)
    "Is the half-open range START..END of S non-empty and all ASCII digits?

`substring' clamps out-of-range indices, so a short string yields an empty part and this
answers False rather than erroring -- which is what lets the shape check below evaluate
every clause eagerly without a length guard in front of each one."
    (let ((part (str:substring s start end)))
      (and (> (str:length part) 0)
           (iter:every! chr:ascii-digit? (str:chars part)))))

  (declare lit-at? (String * UFix * UFix * String -> Boolean))
  (define (lit-at? s start end expected)
    "Is the half-open range START..END of S exactly EXPECTED?"
    (== (str:substring s start end) expected))

  (declare parse-published (String -> (Optional Published)))
  (define (parse-published s)
    "Accept EXACTLY `YYYY-MM-DDTHH:MM:SSZ' -- 20 characters, UTC, no fractional seconds
and no numeric offset. Anything else is `None'.

THIS STRICTNESS IS THE COMPARISON'S CORRECTNESS CONDITION, not tidiness. `published-predates?'
compares lexicographically, which tracks chronology only for a FIXED-WIDTH spelling. Two
valid ISO-8601 timestamps break it, and they break it toward a false negative -- a stale
manifest that is NOT refused:

  \"2026-07-26T14:02:11.500Z\" vs \"2026-07-26T14:02:11Z\" -- common prefix through the
  seconds, then `.' (#x2E) against `Z' (#x5A). The fractional string sorts EARLIER while
  naming the LATER instant. So when the INSTALLED build carries a fraction and the offered
  manifest does not, a manifest that genuinely predates it compares as newer and passes.

  A `+00:00' offset is the same class: it sorts before every `Z' timestamp whatever instant
  it names.

A permissive ISO-8601 parser -- which is what most date libraries are by default -- would
accept both and hand them straight through. So the refusal has to be about the literal
shape rather than about validity, and it has to live in the constructor, because that is
the only place every path into the type must pass.

A NOTE FOR THE SHELL: a manifest carrying a `published' this refuses must be reported as
`Malformed-Manifest', NOT treated as a manifest without one. Absence fails open by design
(see `stale?'); an unparseable value must not inherit that, or mangling the field becomes
the bypass that stripping it cannot be."
    ;; THE LENGTH GUARD MUST SHORT-CIRCUIT, and that is not a stylistic choice: `make-list'
    ;; evaluates every element, and `substring' does NOT clamp safely -- for a string
    ;; shorter than the index it computes start > end and signals. Folding the length test
    ;; into the list below made this function error on every short input instead of
    ;; returning None. Length first, then the shape.
    (if (/= (str:length s) 20)
        None
        (if (lst:all (fn (b) b)
                 (make-list (digits-at? s 0 4)
                            (lit-at? s 4 5 "-")
                            (digits-at? s 5 7)
                            (lit-at? s 7 8 "-")
                            (digits-at? s 8 10)
                            (lit-at? s 10 11 "T")
                            (digits-at? s 11 13)
                            (lit-at? s 13 14 ":")
                            (digits-at? s 14 16)
                            (lit-at? s 16 17 ":")
                            (digits-at? s 17 19)
                            (lit-at? s 19 20 "Z")))
            (Some (%Published s))
            None)))

  (declare published-predates? (Published * Published -> Boolean))
  (define (published-predates? a b)
    "Does A name an earlier instant than B?"
    (match (<=> (published-string a) (published-string b))
      ((LT) True)
      (_ False)))

  (define-type Update-Block
    "Why an update cannot proceed. Every one of these owes the user a sentence."
    ;; The manifest or the payload did not verify. Loud, always: this is either a broken
    ;; release or someone serving us bytes, and both need a human.
    (Bad-Signature String)
    ;; A version not strictly newer than installed, offered for APPLY. Not a check-time
    ;; state -- see `evaluate-candidate' -- but the refusal `apply' makes when handed one.
    (Would-Downgrade ver:Version ver:Version)
    ;; An in-place update cannot work across this gap; the user must run an installer.
    ;; Carries the floor AND the installer URL, because the design's wording is "says so
    ;; plainly and LINKS THE INSTALLER" -- the same escape-hatch shape as
    ;; `Unsupported-Schema', and for the same reason: an outcome the updater cannot fix by
    ;; updating has to arrive with somewhere to click or the user is simply stuck.
    ;;
    ;; THE SEMANTICS ARE DECIDED, and it is worth saying where, because the client this
    ;; module was promoted from declares a `minimum-version' slot that NO code path reads
    ;; -- so a reader of that client would find a plausible name with no decided meaning
    ;; and have to guess between two materially different readings (a floor for direct
    ;; application vs. a floor below which nothing is offered at all). It is not a guess
    ;; here: desktop-distribution-design.md section 3 chose the second -- it "forces a
    ;; manual reinstall when an in-place update cannot work (e.g. the bundle layout
    ;; changed)". That is what is implemented.
    (Needs-Reinstall ver:Version (Optional String))
    ;; A per-machine install. "Ask whoever installed this", never a stack trace.
    Not-Writable
    ;; The build does not know its own version, so nothing can be compared. NOT a network
    ;; problem, though the original reported it as one: an updater that reads "I do not
    ;; know what I am" as "I am current" never offers the fix that matters.
    Unknown-Version
    ;; Well-signed but unusable -- a version string that is not one, a field that is not
    ;; what it claims. Distinct from Bad-Signature because it is a release-process bug,
    ;; not an attack.
    (Malformed-Manifest String)
    ;; The channel has moved to a manifest schema this build cannot read. Carries the
    ;; declared schema and the PERMANENT DOWNLOAD URL, which is what makes it actionable.
    ;;
    ;; THIS IS THE ONE FAILURE AN UPDATER CANNOT FIX BY UPDATING, and it is why #75 asked
    ;; for a permanent download URL distinct from the update channel -- a connection not
    ;; drawn at the time. A client that refuses a newer schema does not refuse once; it
    ;; refuses EVERY check, forever, until a human intervenes. Rendered as a generic
    ;; failure that is a permanent red banner, which a user learns to ignore, and then
    ;; ignores the next one too. So it is its own variant and it must render CALMLY:
    ;; "this build cannot read the current release channel -- download the latest
    ;; directly", with somewhere to click.
    ;;
    ;; THE COROLLARY IS A RULE FOR THE MANIFEST, NOT FOR THE CLIENT. Because a bump forces
    ;; a manual update on every older client in the field, `schema' is an expensive lever
    ;; and the protection is designing it never to be pulled: additive optional fields
    ;; MUST NOT bump it, and a parser MUST ignore unknown keys rather than reject them.
    ;; Bump only when an old client reading the document would do something WRONG, not
    ;; merely something incomplete. Done right, this variant exists and almost never fires.
    (Unsupported-Schema Integer String)
    ;; The manifest is for a different product, or a channel that was not asked for.
    ;; A SUBSTITUTION WORTH REFUSING: serving a valid, correctly signed manifest from
    ;; elsewhere in the same trust domain is a real attack, and one that nothing in the
    ;; promoted client would have noticed -- `product' and `channel' were slots with zero
    ;; read sites. Signed does not mean addressed to us.
    (Manifest-Mismatch String)
    ;; A manifest offering a NEWER version whose `published' instant PREDATES the installed
    ;; build's. Section 2 makes this half of anti-rollback, and it is the half a version
    ;; comparison alone cannot provide: version and time are independent monotonic axes, so
    ;; a channel that ever reuses or resets a version number -- a botched release
    ;; republished under a number already shipped -- defeats the version check completely
    ;; while this one still holds. Loud, because it cannot arise from ordinary use: a
    ;; correctly operated channel never publishes a higher version at an earlier instant,
    ;; so reaching here means a replay, a substitution, or a release process that is broken
    ;; in a way somebody needs to know about.
    (Stale-Manifest Published Published)
    ;; The new build was installed but did not come back up. Section 7 decides what this
    ;; MEANS, and the meaning is not "the update failed": it is ROLL BACK AT NEXT START.
    ;; The previous version is still on disk precisely because of the neighbouring
    ;; invariant -- keep it until the new one has started successfully once -- so the
    ;; recovery exists and this state is what triggers it. Reported as a block because it
    ;; is the one apply outcome a user must be told about: they are running an older build
    ;; than they asked for, deliberately, and that is not something to discover later.
    (Relaunch-Failed ver:Version))

  (define-type Update-State
    "Where an update attempt stands.

Three of these are quiet and one is loud. `Up-To-Date', `No-Artifact' and `Source-Unreachable'
are ordinary outcomes a UI may render as nothing at all; `Blocked' is the one that has
something to say."
    ;; Checked; nothing newer. Also the honest answer for a build with no release channel.
    Up-To-Date
    ;; A channel exists and has something newer -- but not built for THIS platform yet.
    ;; Normal and temporary: a platform can join the matrix a release late.
    No-Artifact
    ;; Could not contact the source. Background noise, not an error to report.
    Source-Unreachable
    ;; A newer build exists and applies here.
    (Available ver:Version)
    ;; Downloaded, verified, on disk, awaiting a restart.
    (Staged ver:Version)
    ;; Handed off to the installer. PROGRESS IS UNREPORTABLE FROM HERE BY CONSTRUCTION,
    ;; not by omission: section 7 hands the Windows payload to NSIS with /S and exits
    ;; immediately so nothing is locked, which means the process that would report
    ;; progress is the one being replaced. The UI says "installing..." until the NEW
    ;; process reports its version. A state, because a progress bar that cannot advance
    ;; is worse than a sentence that explains why.
    (Applying ver:Version)
    ;; The new build is running but has not yet been confirmed, and THE PREVIOUS VERSION
    ;; IS STILL ON DISK. Section 7: keep the old one until the new one has started
    ;; successfully once. Without a state for the window between "started" and
    ;; "confirmed", nothing decides when the old copy may be deleted -- and something
    ;; that is never deleted and never used is how a bundle doubles in size per release.
    (Pending-Confirmation ver:Version)
    (Blocked Update-Block))

  ;;; --- naming, for the CL shell ------------------------------------------------
  ;;
  ;; CL may not destructure a Coalton value, so the shell dispatches on these names. They
  ;; are also the only place each name is written, which is what stops a misspelt state
  ;; reaching a `case' that silently never matches.

  (declare block-name (Update-Block -> String))
  (define (block-name b)
    "A stable, lower-case name for a block reason."
    (match b
      ((Bad-Signature _) "bad-signature")
      ((Would-Downgrade _ _) "would-downgrade")
      ((Needs-Reinstall _ _) "needs-reinstall")
      ((Not-Writable) "not-writable")
      ((Unknown-Version) "unknown-version")
      ((Malformed-Manifest _) "malformed-manifest")
      ((Unsupported-Schema _ _) "unsupported-schema")
      ((Manifest-Mismatch _) "manifest-mismatch")
      ((Stale-Manifest _ _) "stale-manifest")
      ((Relaunch-Failed _) "relaunch-failed")))

  (declare block-detail (Update-Block -> (Optional String)))
  (define (block-detail b)
    "The human-readable specifics, where there are any."
    (match b
      ((Bad-Signature d) (Some d))
      ((Malformed-Manifest d) (Some d))
      ((Would-Downgrade offered installed)
       (Some (<> "offered " (<> (ver:version-string offered)
                                (<> " but running " (ver:version-string installed))))))
      ((Manifest-Mismatch d) (Some d))
      ((Stale-Manifest offered installed)
       (Some (<> "the offered release is dated "
                 (<> (published-string offered)
                     (<> ", which predates the installed build's "
                         (published-string installed))))))
      ((Needs-Reinstall minimum url)
       (Some (<> "a manual reinstall is required to move past "
                 (<> (ver:version-string minimum)
                     (match url
                       ((None) "")
                       ((Some u) (<> "; download the latest version directly from " u)))))))
      ((Unsupported-Schema declared url)
       (Some (<> "this build cannot read release manifest schema "
                 (<> (the String (into declared))
                     (<> "; download the latest version directly from " url)))))
      ((Relaunch-Failed v)
       (Some (<> "version " (<> (ver:version-string v)
                                " was installed but did not start; the previous version will be restored at next start"))))
      ((Not-Writable) None)
      ((Unknown-Version) None)))

  (declare state-name (Update-State -> String))
  (define (state-name s)
    "A stable, lower-case name for a state."
    (match s
      ((Up-To-Date) "up-to-date")
      ((No-Artifact) "no-artifact")
      ((Source-Unreachable) "unreachable")
      ((Available _) "available")
      ((Staged _) "staged")
      ((Applying _) "applying")
      ((Pending-Confirmation _) "pending-confirmation")
      ((Blocked _) "blocked")))

  (declare state-version (Update-State -> (Optional ver:Version)))
  (define (state-version s)
    "The version a state is about, where it is about one."
    (match s
      ((Available v) (Some v))
      ((Staged v) (Some v))
      ((Applying v) (Some v))
      ((Pending-Confirmation v) (Some v))
      (_ None)))

  ;;; --- the decision --------------------------------------------------------------

  ;;; --- the CL-facing surface -----------------------------------------------------
  ;;
  ;; CL MAY NOT CONSTRUCT AN `Optional' OR DESTRUCTURE A COALTON VALUE, so the shell
  ;; cannot call `evaluate-candidate' directly and cannot read what it returns. It can,
  ;; however, HOLD the result opaquely and pass it back. So: one entry point taking plain
  ;; strings, and a handful of accessors that render the result as strings.
  ;;
  ;; The empty string means ABSENT at this boundary. That is only safe because the shell
  ;; validates first -- `valid-published?' and `valid-version?' exist so a MALFORMED value
  ;; can be told apart from a missing one and reported as `Malformed-Manifest'. Collapsing
  ;; the two here would let a mangled timestamp inherit the deliberate fail-open that
  ;; absence gets, which is precisely the bypass `parse-published' was narrowed to prevent.

  (declare valid-published? (String -> Boolean))
  (define (valid-published? s)
    "Does S have the one accepted timestamp spelling? The shell asks BEFORE treating an
empty string as absence, so that malformed and missing stay distinguishable."
    (match (parse-published s)
      ((Some _) True)
      ((None) False)))

  (declare opt-published-text (String -> (Optional Published)))
  (define (opt-published-text s)
    (if (== s "") None (parse-published s)))

  (declare opt-version-text (String -> (Optional ver:Version)))
  (define (opt-version-text s)
    (if (== s "") None (ver:parse-version s)))

  (declare opt-text (String -> (Optional String)))
  (define (opt-text s)
    (if (== s "") None (Some s)))

  (declare decide-from-text (String * String * Boolean * String * String * String * String
                             -> Update-State))
  (define (decide-from-text installed offered artifact? minimum installer-url
                            offered-published installed-published)
    "`evaluate-candidate', driven entirely from CL strings. Empty means absent."
    (evaluate-candidate (opt-version-text installed)
                        (opt-version-text offered)
                        artifact?
                        (opt-version-text minimum)
                        (opt-text installer-url)
                        (opt-published-text offered-published)
                        (opt-published-text installed-published)))

  (declare state-version-text (Update-State -> String))
  (define (state-version-text s)
    "The version a state is about, rendered; the empty string when it is about none."
    (match (state-version s)
      ((Some v) (ver:version-string v))
      ((None) "")))

  (declare state-block-name (Update-State -> String))
  (define (state-block-name s)
    "The block reason's name, or the empty string when the state is not `Blocked'."
    (match s
      ((Blocked b) (block-name b))
      (_ "")))

  (declare state-block-detail (Update-State -> String))
  (define (state-block-detail s)
    "The block reason's sentence, or the empty string."
    (match s
      ((Blocked b)
       (match (block-detail b)
         ((Some d) d)
         ((None) "")))
      (_ "")))

  (declare stale? ((Optional Published) * (Optional Published) -> Boolean))
  (define (stale? offered-published installed-published)
    "Is the offered release dated earlier than the installed build?

BOTH TIMESTAMPS MUST BE PRESENT for this to fire. A manifest that omits `published', or a
build that does not know its own, cannot be compared -- and this deliberately does NOT
block in that case, because the version comparison above has already run and is the decided
primary check. Making an absent timestamp fatal would turn every pre-timestamp build into
one that can never update again: a denial-of-update delivered by us rather than by an
attacker, which is the same failure the schema gate has to avoid.

THIS FAIL-OPEN IS SAFE ONLY BECAUSE VERIFICATION PRECEDES INTERPRETATION. An attacker
cannot strip `published' to disable the check, because removing a field breaks the
signature over the manifest's exact bytes; absence can therefore only come from a
legitimately signed manifest that genuinely lacks the field. Reorder the shell to parse
before verifying -- the \"helpful refactor\" the module header warns about -- and this
stops being a fail-open and becomes an ATTACKER-SELECTABLE BYPASS. Two decisions coupled
across two files, invisible from either end, so each says so."
    (match (Tuple offered-published installed-published)
      ((Tuple (Some o) (Some i)) (published-predates? o i))
      (_ False)))

  (declare stale-block ((Optional Published) * (Optional Published) -> Update-State))
  (define (stale-block offered-published installed-published)
    "The blocked state for a stale manifest. Only reached when `stale?' is true, which
means both timestamps are present; the fallback exists to keep the function total."
    (match (Tuple offered-published installed-published)
      ((Tuple (Some o) (Some i)) (Blocked (Stale-Manifest o i)))
      (_ Up-To-Date)))

  (declare evaluate-candidate ((Optional ver:Version) * (Optional ver:Version) * Boolean
                               * (Optional ver:Version) * (Optional String)
                               * (Optional Published) * (Optional Published) -> Update-State))
  (define (evaluate-candidate installed offered artifact? minimum installer-url
                              offered-published installed-published)
    "Decide what the shell should report, from what it already knows.

INSTALLED is this build's version -- `None' when it does not know, which is a block and
never a silent \"current\". OFFERED is the manifest's version, `None' when there was no
manifest at all. ARTIFACT? is whether the manifest carries a payload for this platform.
MINIMUM is the manifest's `minimum_version', below which an in-place update cannot work.
INSTALLER-URL is where a human may download the build directly, carried into
`Needs-Reinstall' so that refusal arrives with somewhere to click. OFFERED-PUBLISHED and
INSTALLED-PUBLISHED are the two `published' instants, and they are the SECOND HALF of
anti-rollback -- see step 4.

ORDER MATTERS AND IS DELIBERATE:

  1. An unknown installed version blocks everything -- there is nothing to compare against
     and every branch below is a comparison.
  2. No manifest is `Up-To-Date'. For a working-tree build with the default source that is
     the true answer, not a stub's pretence.
  3. NOT STRICTLY NEWER IS `Up-To-Date', which is the anti-rollback refusal. Equal is not
     newer; older is not newer. A replayed stale manifest is correctly signed -- we signed
     it -- so a signature check cannot refuse it and only this comparison can. It is
     reported quietly rather than as an attack because the benign case is common: a
     developer running a local build ahead of the channel hits this branch every day.
     `Would-Downgrade' is the LOUD counterpart, raised by `apply' when someone hands it an
     older version outright.
  4. A newer version published EARLIER than the installed build is refused, loudly. This
     is the half of anti-rollback a version comparison cannot provide -- section 2 decides
     both halves -- and it is checked after the version test because it only has meaning
     for a manifest that already claims to be newer.
  5. No artifact for this platform, before the minimum-version check: with nothing built
     for this machine there is nothing to install and nothing to reinstall either, so the
     accurate report is that the platform is not covered yet.
  6. Below the minimum, an in-place update cannot work -- say so and point at an installer."
    (match installed
      ((None) (Blocked Unknown-Version))
      ((Some current)
       (match offered
         ((None) Up-To-Date)
         ((Some new)
          (if (not (ver:version-newer? new current))
              Up-To-Date
              (if (stale? offered-published installed-published)
                  (stale-block offered-published installed-published)
                  (if (not artifact?)
                      No-Artifact
                      (match minimum
                        ((None) (Available new))
                        ((Some floor)
                         (if (ver:version-newer? floor current)
                             (Blocked (Needs-Reinstall floor installer-url))
                             (Available new)))))))))))))
