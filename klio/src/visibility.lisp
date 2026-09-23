;;;; visibility.lisp --- whether a piece of content is published, and when.
;;;;
;;;; Request-time scheduling (#359, Part 2 item 1). A post with a future `publish-at' becomes
;;;; visible when the time passes. No timer, no database, no deploy: a listing asks this
;;;; question when it is built, and the answer changes on its own.
;;;;
;;;; Pure. The clock is an argument, which is what makes the scheduled case testable without
;;;; waiting.

(in-package #:klio)

(defun visibility (&key draft publish-at now)
  "What state this content is in: :PUBLISHED, :DRAFT or :SCHEDULED.

DRAFT is a flag the author sets. PUBLISH-AT is a universal time or NIL. NOW is a universal
time, passed in rather than read, so a test can ask what a post looks like next Tuesday.

A draft with a publish-at is still a draft. The flag is the author saying not yet, and a date
is not an argument against it."
  (cond (draft :draft)
        ((and publish-at now (> publish-at now)) :scheduled)
        (t :published)))

(defun visible-p (&key draft publish-at now)
  "True when this content should appear to a reader. The dev-mode exception is not here --
a caller in dev mode shows everything, which is a decision about the caller, not the content."
  (eq :published (visibility :draft draft :publish-at publish-at :now now)))
