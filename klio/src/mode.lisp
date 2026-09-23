;;;; mode.lisp --- development mode.
;;;;
;;;; Part 2 item 3 of pre-publication issue 359: preview is a flag, not a URL.
;;;;
;;;; A secret production URL that shows drafts is an authentication surface with no
;;;; authentication. It ships once, gets shared, and is found by a scanner. A flag cannot leak
;;;; because it is not reachable from the network at all.
;;;;
;;;; ADR-0001 gives this a second job: dev mode is the documented exception to the
;;;; all-or-nothing content swap. In production a bad file means the tree is not published; in
;;;; dev it is skipped and reported, because someone editing wants to see the rest of the page
;;;; they are working on and no reader is affected.

(in-package #:klio)

(defvar *dev-mode* nil
  "True in a development image. Off by default, so production is what you get unless somebody
says otherwise -- the opposite default would make a forgotten flag a disclosure.")

(defun dev-mode-p () (and *dev-mode* t))

(defmacro with-dev-mode ((&optional (on t)) &body body)
  "Run BODY with *DEV-MODE* bound to ON. For tests and for a site's dev entry point."
  `(let ((*dev-mode* ,on)) ,@body))

(defun readable-p (&key draft publish-at now)
  "Should this content be rendered for the current audience?

In production, only published content. In dev mode, everything -- a draft is exactly what the
author wants to look at. This is the only place the two audiences differ, which is why
VISIBLE-P stays a pure statement about the content and does not consult the mode itself."
  (or (dev-mode-p) (visible-p :draft draft :publish-at publish-at :now now)))
