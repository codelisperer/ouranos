;;;; toggle.lisp --- the segmented control and the toggle group (#981)
;;;;
;;;; Both are a row of buttons in a named group, each with aria-pressed. A segmented control
;;;; has exactly one pressed button, such as the current view; a toggle group has any number,
;;;; each independent. Each button is its own tab stop and is pressed with Enter or Space,
;;;; which a <button> does without script, so there is no roving tabindex: these are buttons,
;;;; not a radio group.
;;;;
;;;; A button loads its HREF with htmx (hx-get) into HX-TARGET and pushes the URL. The app's
;;;; HREF is the URL of the state the press leads to, so the server decides what is pressed
;;;; and the next response renders it.

(cl:defpackage #:hyperion/kit/toggle
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret))
  (:documentation
   "A segmented control (SEGMENTED-CONTROL, one choice) and a toggle group (TOGGLE-GROUP,
    independent choices), as buttons with aria-pressed in a labelled group, written with
    Spinneret.")
  (:export #:segmented-control #:toggle-group))

(in-package #:hyperion/kit/toggle)

(defun %buttons (class label options pressed-p hx-target hx-swap)
  (spin:with-html
    (:div :class class :role "group" :aria-label label
      (loop for (value text href) in options
            do (spin:with-html
                 (:button :type "button" :class "button"
                          :aria-pressed (if (funcall pressed-p value) "true" "false")
                          :data-value value
                          :hx-get href :hx-target hx-target
                          :hx-swap hx-swap :hx-push-url "true"
                   text))))))

(defun %default-swap (hx-target)
  (if (equal hx-target "body") "innerHTML" "outerHTML"))

(defun %check-options (options)
  (dolist (o options)
    (destructuring-bind (value text href) o
      (unless (and (stringp value) (stringp text) (stringp href))
        (error "An option is (VALUE TEXT HREF), three strings, not ~S." o)))))

(defun segmented-control (label options &key selected (hx-target "body")
                                             (hx-swap (%default-swap hx-target)))
  "Write a segmented control into SPINNERET:*HTML*: a group named LABEL with one button per
option in OPTIONS, a list of (VALUE TEXT HREF) strings. The option whose VALUE is SELECTED
has aria-pressed=\"true\" and every other has \"false\". Signals unless SELECTED names
exactly one option, because a segmented control always shows one choice.

Pressing a button loads its HREF into HX-TARGET with htmx and pushes the URL. HX-TARGET
defaults to \"body\", which takes the whole page as the response. HX-SWAP defaults to
\"innerHTML\" for the body and \"outerHTML\" for any other target, the way hyperion/list
replaces its list."
  (%check-options options)
  (unless (= 1 (count selected options :key #'first :test #'equal))
    (error "SELECTED ~S names no option, or more than one, of ~S." selected
           (mapcar #'first options)))
  (%buttons "hy-segmented" label options (lambda (v) (equal v selected)) hx-target hx-swap))

(defun toggle-group (label options &key pressed (hx-target "body")
                                        (hx-swap (%default-swap hx-target)))
  "Write a toggle group into SPINNERET:*HTML*: a group named LABEL with one button per option
in OPTIONS, a list of (VALUE TEXT HREF) strings. Each option whose VALUE is in PRESSED, a
list of strings, has aria-pressed=\"true\"; the others have \"false\". Any number may be
pressed, including none. A button's HREF is the URL with that option switched.

Pressing a button loads its HREF into HX-TARGET with htmx and pushes the URL. HX-TARGET and
HX-SWAP default as for SEGMENTED-CONTROL."
  (%check-options options)
  (%buttons "hy-toggle-group" label options
            (lambda (v) (member v pressed :test #'equal)) hx-target hx-swap))
