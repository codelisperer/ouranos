;;;; changeset-tests.lisp --- the example's changeset path (#94).
;;;;
;;;; WHY THIS FILE EXISTS AT ALL. `contacts/tests' was DECLARED with no components and no
;;;; `:perform (test-op ...)':
;;;;
;;;;     (defsystem "contacts/tests"
;;;;       :components ((:module "tests" :components ())))
;;;;
;;;; A test system with nothing in it and no way to run it. It could be loaded, it would
;;;; report success, and it asserted nothing -- which is the same exit code as a suite that
;;;; passes. So the example whose whole purpose is to demonstrate correct use of mnemosyne
;;;; had no check over any of it.
;;;;
;;;; WHAT IS TESTED HERE, AND WHY IT IS THE PURE HALF. `contact-changeset' takes params and
;;;; returns a changeset: no connection, no console, no clock. That is what makes the RULES
;;;; testable without a database, and it is the reason the changeset is a value rather than
;;;; a side effect. The insert itself needs SQLite and is not exercised here; what is
;;;; exercised is every decision made before anything is written, which is where the
;;;; doctrine lives.
;;;;
;;;; THE MASS-ASSIGNMENT TEST IS THE ONE THAT MATTERS, and it is the reason to put this in
;;;; an example rather than only in mnemosyne's own suite. A reader copying `cmd-add' into
;;;; an HTTP handler inherits `+add-allowed+'; the test says out loud what that list is
;;;; defending, so nobody widens it to "every column" for convenience without a red bar.

(cl:defpackage #:mnemosyne/examples/contacts/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:app #:mnemosyne/examples/contacts)
                    (#:cs  #:mnemosyne/changeset))
  (:export #:run-tests))

(in-package #:mnemosyne/examples/contacts/tests)

(def-suite contacts
  :description "The contacts example's cast -> validate path, and its argument parsing.")
(in-suite contacts)

(defun run-tests () (run! 'contacts))

;;; --- cast: what may and may not move ---------------------------------------

(test only-permitted-fields-move
  "SAFE MASS-ASSIGNMENT, stated as an assertion rather than as a comment.

A caller must not be able to set `_id' or `vid' by including them in params -- those are the
framework's to stamp. This is the property `+add-allowed+' exists for, and it is invisible
in review because the guard is the ABSENCE of a field from a list."
  (let ((cs (app::contact-changeset
             (list :name "Ada Lovelace" :_id "forged" :vid 99 :created_by "forged"))))
    (is (cs:changeset-valid-p cs))
    (is (equal "Ada Lovelace" (cs:get-change cs :name)))
    (is (not (nth-value 1 (cs:get-change cs :_id)))    "_id must never move from params")
    (is (not (nth-value 1 (cs:get-change cs :vid)))    "vid must never move from params")
    (is (not (nth-value 1 (cs:get-change cs :created_by)))
        "created_by must never move from params")))

(test a-hash-table-is-accepted
  "#94 assumed `nothing bridges a stamped hash-table to cast'. It does -- `%param-get'
takes a plist, an alist or a hash-table. Asserted here because that assumption is what made
the whole issue read as blocked."
  (let ((h (make-hash-table)))
    (setf (gethash :name h) "Grace Hopper" (gethash :role h) "Rear Admiral")
    (let ((cs (app::contact-changeset h)))
      (is (cs:changeset-valid-p cs))
      (is (equal "Grace Hopper" (cs:get-change cs :name)))
      (is (equal "Rear Admiral" (cs:get-change cs :role))))))

;;; --- validate --------------------------------------------------------------

(test a-missing-name-is-refused
  (let ((cs (app::contact-changeset (list :email "a@b.c"))))
    (is (not (cs:changeset-valid-p cs)))
    (is (assoc :name (cs:changeset-errors cs)))))

(test a-blank-name-is-refused-too
  "Absent and empty are different inputs and must reach the same refusal. The old code
coerced both to \"\" and refused neither."
  (let ((cs (app::contact-changeset (list :name ""))))
    (is (not (cs:changeset-valid-p cs)))
    (is (assoc :name (cs:changeset-errors cs)))))

(test a-malformed-email-is-refused-and-an-absent-one-is-not
  "BOTH DIRECTIONS, because a validator that refuses everything passes the first half.
An omitted optional field must stay optional -- `validate-change' lets absent fields pass,
and that is the behaviour being relied on."
  (let ((bad (app::contact-changeset (list :name "Ada" :email "not-an-email")))
        (absent (app::contact-changeset (list :name "Ada"))))
    (is (not (cs:changeset-valid-p bad)))
    (is (equal "does not look like an email address" (cdr (assoc :email (cs:changeset-errors bad)))))
    (is (cs:changeset-valid-p absent) "an omitted email must not be an error")))

(test the-email-check-is-weak-on-purpose-but-not-useless
  "Pinning the shape of `plausible-email-p'. It is deliberately permissive -- a strict
validator that rejects real addresses would be a worse lesson than a loose one -- but it
must still reject the cases the example's own error message promises to catch."
  (is (app::plausible-email-p "ada@analytical.engine"))
  (is (app::plausible-email-p "a@b"))
  (is (not (app::plausible-email-p "no-at-sign")))
  (is (not (app::plausible-email-p "@leading")))
  (is (not (app::plausible-email-p "trailing@")))
  (is (not (app::plausible-email-p "two@at@signs")))
  (is (not (app::plausible-email-p "has space@x.y"))))

(test an-over-long-name-is-refused
  (let ((cs (app::contact-changeset (list :name (make-string 200 :initial-element #\a)))))
    (is (not (cs:changeset-valid-p cs)))
    (is (assoc :name (cs:changeset-errors cs)))))

;;; --- argument parsing: the half that removed the workaround ----------------

(test a-name-may-contain-spaces
  "THE WORKAROUND THIS REPLACED. `add' split on whitespace and demanded a single token, so
the seed data was hyphenated -- \"Ada-Lovelace\" -- and the demo's data was shaped by a
missing validation path rather than by anything about contacts."
  (let ((params (app::parse-add-line "Ada Lovelace, ada@analytical.engine, Mathematician")))
    (is (equal "Ada Lovelace" (getf params :name)))
    (is (equal "ada@analytical.engine" (getf params :email)))
    (is (equal "Mathematician" (getf params :role)))))

(test omitted-trailing-fields-are-absent-not-blank
  "Absent and \"\" are different to a changeset: one is simply not cast, the other is a
value that fails `validate-required'. Flattening them is what the old code did."
  (let ((params (app::parse-add-line "Ada Lovelace")))
    (is (equal "Ada Lovelace" (getf params :name)))
    (is (not (nth-value 1 (get-properties params '(:email)))))
    (is (not (nth-value 1 (get-properties params '(:role)))))))

(test an-empty-add-line-yields-no-params
  "Which is what makes `cmd-add' print usage rather than construct an empty contact."
  (is (null (app::parse-add-line "")))
  (is (null (app::parse-add-line "   "))))

(test rest-of-line-drops-only-the-command
  (is (equal "Ada Lovelace, ada@x" (app::rest-of-line "add Ada Lovelace, ada@x")))
  (is (equal "" (app::rest-of-line "add")))
  (is (equal "" (app::rest-of-line "  add  "))))
