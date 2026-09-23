;;;; hermes.lisp --- hermes entry: version.
;;;;
;;;; The public surface is the DELIVER protocol + SEND (protocol.lisp), the neutral messages
;;;; (message.lisp), the SendGrid/Twilio/dev backends, and the conditions; receive is
;;;; hermes/inbound. See docs/roadmap.md and the package docstrings.

(cl:in-package #:hermes)

(defparameter +version+ "0.0.0"
  "hermes version.")

(defun version ()
  "Return the hermes version string."
  +version+)
