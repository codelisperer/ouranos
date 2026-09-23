;;;; env-scan-tests.lisp --- `cons env`: which keys does this project need? (#120)
;;;;
;;;; The parser is the part that can be wrong, and it is wrong in a specific direction: a
;;;; .env.example is mostly PROSE, so the hazard is reading commentary as configuration.
;;;; Most of what follows is that boundary -- what counts as a declaration and what is just
;;;; a sentence that happens to contain an `=`.

(in-package #:cons/tests)
(in-suite all)

(defun %example (contents)
  "Parse CONTENTS as a .env.example belonging to system \"lib\"."
  (let ((path (merge-pathnames (format nil "cons-envscan-~D-~D.example"
                                       (get-universal-time) (incf *fake-system-counter*))
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (o path :direction :output :if-exists :supersede)
             (write-string contents o))
           (cons/env-scan:parse-example path "lib"))
      (ignore-errors (delete-file path)))))

(defun %names (keys) (mapcar #'cons/env-scan:declared-key-name keys))

(test a-live-key-is-required-and-a-commented-one-is-optional
  ;; The convention every .env.example in this tree already follows: a live line is a key
  ;; the library expects, a commented one is an override you may set. Aggregation is much
  ;; less useful if that distinction is flattened -- "thirty keys" versus "these four must
  ;; be set" is the difference between a list and an answer.
  (let ((keys (%example "LIVE_KEY=value
# COMMENTED_KEY=value
")))
    (is (equal '("LIVE_KEY" "COMMENTED_KEY") (%names keys)))
    (is (cons/env-scan:declared-key-requiredp (first keys)))
    (is (not (cons/env-scan:declared-key-requiredp (second keys))))))

(test prose-is-not-configuration
  ;; The whole risk of scanning these files. Each of these lines contains an `=` or looks
  ;; keyish, and none of them is a declaration.
  (let ((keys (%example "# --- transport selection ------------------------------------
# Per-channel provider (used when SOMETHING is unset):
# Set FOO=bar to enable the thing
# see https://example.com/docs?a=b
# lowercase_key=nope
REAL_KEY=yes
")))
    (is (equal '("REAL_KEY") (%names keys))
        "only the real declaration should survive; got ~S" (%names keys))))

(test a-key-keeps-the-comment-that-explains-it
  ;; A union of thirty bare names is not much help. The prose above a key is how a library
  ;; says what the key is for, so it has to travel with it into the generated file.
  (let ((keys (%example "# The SendGrid API key. Required once the sendgrid transport
# is selected; ignored otherwise.
# SENDGRID_API_KEY=REPLACE_ME
")))
    (is (= 1 (length keys)))
    (is (search "SendGrid API key" (cons/env-scan:declared-key-comment (first keys))))
    (is (search "ignored otherwise" (cons/env-scan:declared-key-comment (first keys))))))

(test a-blank-line-ends-a-comment-block
  ;; Otherwise the file header -- which explains the FILE, not any key -- gets attached to
  ;; whatever key happens to come first.
  (let ((keys (%example "# This paragraph is about the file as a whole.

# This one is about the key.
KEY=v
")))
    (let ((comment (cons/env-scan:declared-key-comment (first keys))))
      (is (search "about the key" comment))
      (is (not (search "as a whole" comment))
          "the file header must not be attributed to the first key"))))

(test an-inline-comment-is-not-part-of-the-key
  (let ((keys (%example "# TWILIO_FROM=+15551234567        # default outbound sender (E.164)
")))
    (is (equal '("TWILIO_FROM") (%names keys)))))

(test every-key-is-attributed-to-the-system-that-declared-it
  ;; Without this the union is a wall of names with no way to tell who wants which, and no
  ;; way to know what becomes dead when a dependency is dropped.
  (let ((keys (%example "A_KEY=1")))
    (is (string= "lib" (cons/env-scan:declared-key-system (first keys))))))

;;; --- against the real tree -------------------------------------------------

(test scanning-hermes-finds-the-keys-it-actually-declares
  ;; A real .env.example, not a fixture: hermes declares its transport selection and its
  ;; two providers' credentials, all as optional overrides.
  (let* ((keys (cons/env-scan:scan :hermes))
         (names (%names keys)))
    (is (member "SENDGRID_API_KEY" names :test #'string=))
    (is (member "TWILIO_AUTH_TOKEN" names :test #'string=))
    (is (member "HERMES_TRANSPORT" names :test #'string=))
    ;; every one of hermes' keys is a commented-out override
    (is (notany #'cons/env-scan:declared-key-requiredp keys))
    ;; and each is attributed
    (is (every (lambda (k) (string= "hermes" (cons/env-scan:declared-key-system k))) keys))))

(test a-key-declared-twice-appears-once
  ;; Two libraries wanting the same key is one key. A generated file with duplicate
  ;; entries would be worse than no generated file.
  (let ((keys (cons/env-scan:scan :hermes)))
    (is (= (length keys) (length (remove-duplicates (%names keys) :test #'string=))))))

(test key-status-reads-the-live-environment
  (if (not (env-writable-p))
      (skip "this build cannot mutate the C environment that uiop:getenv reads")
      (let ((keys (%example "CONS_TEST_STATUS=x
# CONS_TEST_OPTIONAL=y
")))
        (unset-env "CONS_TEST_STATUS")
        (unset-env "CONS_TEST_OPTIONAL")
        ;; a required key with nothing set is the case worth shouting about
        (is (eq :missing (cons/env-scan:key-status (first keys))))
        ;; an optional one is merely unset
        (is (eq :unset (cons/env-scan:key-status (second keys))))
        (set-env "CONS_TEST_STATUS" "present")
        (is (eq :set (cons/env-scan:key-status (first keys))))
        (unset-env "CONS_TEST_STATUS"))))

(test report-counts-the-missing-required-keys
  ;; The return value is what lets `cons env` exit non-zero and gate a deploy.
  (if (not (env-writable-p))
      (skip "this build cannot mutate the C environment that uiop:getenv reads")
      (let ((out (make-string-output-stream)))
        ;; hermes declares only optional keys, so nothing is MISSING however bare the
        ;; environment is -- which is itself the behaviour worth pinning
        (is (zerop (cons/env-scan:report :hermes :stream out)))
        (let ((text (get-output-stream-string out)))
          (is (search "SENDGRID_API_KEY" text))
          (is (search "hermes" text) "the report must say who wants each key")))))

;;; --- generating the app-level file ----------------------------------------
;;;
;;; The property that matters most here is APPEND-NEVER-REWRITE. The app's own keys, its
;;; comments and its ordering belong to its author; a generator that rewrote the file would
;;; eat them the first time a dependency changed, and the author would find out later.

(defun %temp-example (contents)
  (let ((path (merge-pathnames (format nil "cons-agg-~D-~D.example"
                                       (get-universal-time) (incf *fake-system-counter*))
                               (uiop:temporary-directory))))
    (with-open-file (o path :direction :output :if-exists :supersede)
      (write-string contents o))
    path))

(test sync-appends-dependency-keys-and-leaves-what-was-there
  (let ((path (%temp-example "# my own header, which must survive
MY_OWN_KEY=mine
")))
    (unwind-protect
         (let ((added (cons/env-scan:sync "someapp" :path path :dependencies '("hermes")
                                                    :stream (make-broadcast-stream))))
           (is (member "SENDGRID_API_KEY" added :test #'string=))
           (let ((text (uiop:read-file-string path)))
             (is (search "my own header, which must survive" text)
                 "the author's comments must not be rewritten away")
             (is (search "MY_OWN_KEY=mine" text) "nor their keys")
             (is (search "SENDGRID_API_KEY" text) "and the dependency's keys are now there")
             (is (search "hermes" text) "attributed to whoever wants them")))
      (ignore-errors (delete-file path)))))

(test sync-run-twice-adds-nothing-the-second-time
  ;; It is run at `cons init` and again whenever a dependency is added, so a repeat must be
  ;; a no-op rather than a growing pile of duplicate blocks.
  (let ((path (%temp-example "")))
    (unwind-protect
         (progn
           (cons/env-scan:sync "someapp" :path path :dependencies '("hermes")
                                         :stream (make-broadcast-stream))
           (let ((before (uiop:read-file-string path)))
             (is (null (cons/env-scan:sync "someapp" :path path :dependencies '("hermes")
                                                     :stream (make-broadcast-stream))))
             (is (string= before (uiop:read-file-string path))
                 "a second sync must not touch the file at all")))
      (ignore-errors (delete-file path)))))

(test a-key-the-author-commented-out-is-not-re-added
  ;; Commenting a key out is a decision. Re-appending it would be the generator arguing
  ;; with the author every time it runs.
  (let ((path (%temp-example "# SENDGRID_API_KEY=deliberately-not-using-this
")))
    (unwind-protect
         (let ((added (cons/env-scan:sync "someapp" :path path :dependencies '("hermes")
                                                    :stream (make-broadcast-stream))))
           (is (not (member "SENDGRID_API_KEY" added :test #'string=)))
           ;; and it appears exactly once in the file, still commented
           (let ((text (uiop:read-file-string path)))
             (is (= 1 (count-if (lambda (line) (search "SENDGRID_API_KEY" line))
                                (uiop:split-string text :separator '(#\Newline)))))))
      (ignore-errors (delete-file path)))))

(test sync-creates-the-file-when-there-is-none
  (let ((path (merge-pathnames (format nil "cons-agg-new-~D-~D.example"
                                       (get-universal-time) (incf *fake-system-counter*))
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (is (not (probe-file path)))
           (cons/env-scan:sync "someapp" :path path :dependencies '("hermes")
                                         :stream (make-broadcast-stream))
           (is (probe-file path))
           (is (search "SENDGRID_API_KEY" (uiop:read-file-string path))))
      (ignore-errors (delete-file path)))))

(test render-keeps-required-live-and-optional-commented
  ;; The distinction has to survive into the generated file, or the union stops being an
  ;; answer to "what must I actually set".
  (let* ((keys (%example "REQUIRED_ONE=x
# OPTIONAL_ONE=y
"))
         (text (with-output-to-string (o) (cons/env-scan:render keys :stream o))))
    (is (search (format nil "~%REQUIRED_ONE=") text) "a required key is emitted live")
    (is (search "# OPTIONAL_ONE=" text) "an optional one stays commented")))

(test scan-systems-answers-for-a-project-that-does-not-exist-yet
  ;; What `cons init` needs: the scaffold is written before anything is on the ASDF path,
  ;; so the question can only be asked of the dependency LIST.
  (let ((keys (cons/env-scan:scan-systems '("hermes"))))
    (is (member "SENDGRID_API_KEY" (%names keys) :test #'string=))))

(test an-uninstallable-dependency-is-skipped-rather-than-fatal
  ;; Scaffolding must work before the dependencies are fetched, and `cons env` must stay
  ;; useful in a checkout missing one optional dependency.
  (let ((keys (cons/env-scan:scan-systems '("hermes" "no-such-system-anywhere"))))
    (is (member "SENDGRID_API_KEY" (%names keys) :test #'string=))))
