;;;; version.lisp --- version algebra for the updater (Coalton, #76).
;;;;
;;;; THIS FILE IS THE ANTI-ROLLBACK DEFENCE. Everything else in the updater is plumbing
;;;; around one question -- is the offered version strictly newer than the installed one --
;;;; and a wrong answer here is a downgrade attack that every signature check passes.
;;;;
;;;; The attack is worth stating plainly, because it is not obvious that a correctly
;;;; signed manifest can be hostile. An attacker who can serve bytes replays LAST MONTH'S
;;;; manifest: real, genuinely signed, and advertising a real past release with a known
;;;; hole in it. Signature verification cannot refuse it -- the signature is valid, because
;;;; we made it. The server is authoritative about what is CURRENT; only the client knows
;;;; what it HAS, so only the client can refuse. That is why the comparison lives in the
;;;; typed core with exhaustive tests rather than as a string compare at a call site.
;;;;
;;;; NO BUILD METADATA. Semver's `+sha' does not participate in precedence, so carrying it
;;;; would admit two values that compare EQ while being distinguishable -- a trap in a
;;;; module whose entire purpose is comparison. It is dropped at parse time.

(cl:in-package #:hyperion/update/version)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Version
    "A semantic version: major, minor, patch, and an optional prerelease tag."
    (Version Integer Integer Integer (Optional String)))

  (declare version-major (Version -> Integer))
  (define (version-major v)
    "The major component."
    (match v ((Version x _ _ _) x)))

  (declare version-minor (Version -> Integer))
  (define (version-minor v)
    "The minor component."
    (match v ((Version _ x _ _) x)))

  (declare version-patch (Version -> Integer))
  (define (version-patch v)
    "The patch component."
    (match v ((Version _ _ x _) x)))

  (declare version-prerelease (Version -> (Optional String)))
  (define (version-prerelease v)
    "The prerelease tag, if any. `None' is a full release."
    (match v ((Version _ _ _ x) x)))

  ;;; --- parsing ----------------------------------------------------------------
  ;;
  ;; STRICTER THAN `parse-int' ALONE, ON PURPOSE. Coalton's `parse-int' is
  ;; `:junk-allowed', so it reads "3nonsense" as 3 -- which would make "1.2.3nonsense"
  ;; parse cleanly as 1.2.3. In a comparison that gates applying a binary, quietly
  ;; accepting a malformed version is how a version that is not what it claims gets
  ;; treated as one that is. Every component must be non-empty and all digits.

  (declare digits? (String -> Boolean))
  (define (digits? s)
    "True when S is non-empty and entirely ASCII digits."
    (and (> (str:length s) 0)
         (iter:every! chr:ascii-digit? (str:chars s))))

  (declare parse-component (String -> (Optional Integer)))
  (define (parse-component s)
    "Parse one numeric component, refusing anything `parse-int' would tolerate."
    (if (digits? s) (str:parse-int s) None))

  (declare split-prerelease (String -> (Tuple String (Optional String))))
  (define (split-prerelease s)
    "Split at the FIRST hyphen: the core, and the prerelease tag if present.

The first hyphen, not the last and not every hyphen -- a tag may legitimately contain
them (`1.0.0-rc-2')."
    (match (str:substring-index "-" s)
      ((None) (Tuple s None))
      ((Some i) (Tuple (str:substring s 0 i)
                       (Some (str:substring s (+ i 1) (str:length s)))))))

  (declare prerelease-ok? ((Optional String) -> Boolean))
  (define (prerelease-ok? p)
    "A present-but-empty tag (`1.2.3-') is malformed, not a release."
    (match p
      ((None) True)
      ((Some x) (> (str:length x) 0))))

  (declare parse-version (String -> (Optional Version)))
  (define (parse-version s)
    "Parse \"1.2.3\" or \"1.2.3-beta.1\", with an optional leading \"v\".

`None' for anything else. The caller decides what a malformed version means; in the
updater it means the manifest is not trustworthy, which is never an upgrade."
    (let ((trimmed (match (str:strip-prefix "v" s)
                     ((Some rest) rest)
                     ((None) s))))
      (match (split-prerelease trimmed)
        ((Tuple core pre)
         (if (prerelease-ok? pre)
             (match (str:split #\. core)
               ((Cons a (Cons b (Cons c (Nil))))
                (do (mj <- (parse-component a))
                    (mn <- (parse-component b))
                    (pt <- (parse-component c))
                    (pure (Version mj mn pt pre))))
               (_ None))
             None)))))

  ;;; --- rendering --------------------------------------------------------------

  (declare version-string (Version -> String))
  (define (version-string v)
    "Render canonically, with no leading \"v\". `parse-version' round-trips this."
    (match v
      ((Version mj mn pt pre)
       (let ((core (<> (the String (into mj))
                       (<> "."
                           (<> (the String (into mn))
                               (<> "." (the String (into pt))))))))
         (match pre
           ((None) core)
           ((Some p) (<> core (<> "-" p))))))))

  ;;; --- comparison -------------------------------------------------------------

  (declare compare-prerelease ((Optional String) * (Optional String) -> Ordering))
  (define (compare-prerelease a b)
    "A prerelease is LESS than the release it precedes: 1.0.0-rc1 < 1.0.0.

Tags themselves compare lexicographically, which is a documented simplification --
semver's dotted-identifier rules would make `rc.10' sort after `rc.9', and here it
sorts before. It has never mattered because release tags are compared against the
INSTALLED version, which for a shipped build is a full release; if a product ever ships
double-digit release candidates to users, this is the line to fix."
    (match (Tuple a b)
      ((Tuple (None) (None)) EQ)
      ((Tuple (None) (Some _)) GT)
      ((Tuple (Some _) (None)) LT)
      ((Tuple (Some x) (Some y)) (<=> x y))))

  (declare version-compare (Version * Version -> Ordering))
  (define (version-compare a b)
    "Order two versions. Monomorphic so the CL shell can call it directly."
    (match (Tuple a b)
      ((Tuple (Version amj amn apt apre) (Version bmj bmn bpt bpre))
       (if (/= amj bmj)
           (<=> amj bmj)
           (if (/= amn bmn)
               (<=> amn bmn)
               (if (/= apt bpt)
                   (<=> apt bpt)
                   (compare-prerelease apre bpre)))))))

  (define-instance (Eq Version)
    (define (== a b)
      (match (version-compare a b)
        ((EQ) True)
        (_ False))))

  (define-instance (Ord Version)
    (define (<=> a b) (version-compare a b)))

  (declare version-newer? (Version * Version -> Boolean))
  (define (version-newer? candidate installed)
    "Is CANDIDATE strictly newer than INSTALLED?

STRICTLY. Equal is not newer, and re-applying the installed version is not an update --
it is the replay this module exists to refuse."
    (match (version-compare candidate installed)
      ((GT) True)
      (_ False)))

  (declare valid-version? (String -> Boolean))
  (define (valid-version? s)
    "Does S parse? The CL shell asks so it can tell a MALFORMED version in a manifest from
an absent one -- the first is `Malformed-Manifest', the second is simply nothing on offer."
    (match (parse-version s)
      ((Some _) True)
      ((None) False)))

  (declare version-same? (Version * Version -> Boolean))
  (define (version-same? a b)
    "Do two versions denote the same release?"
    (match (version-compare a b)
      ((EQ) True)
      (_ False))))
