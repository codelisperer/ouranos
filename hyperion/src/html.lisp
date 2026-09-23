;;;; html.lisp --- rendering the typed HTMX vocabulary from the CL/Spinneret side.
;;;;
;;;; Thin CL accessors that call the pure Coalton renderers in hyperion/htmx (the
;;;; typed values are constructed and rendered on the Coalton side; CL passes a
;;;; keyword/scalar and gets the attribute string back), plus a generic OOB
;;;; combinator. This is the CL half of "Coalton owns the vocabulary; CLOS +
;;;; Spinneret own rendering." App code uses these to fill hx-* attributes without
;;;; hand-writing attribute strings.

(in-package #:hyperion/html)

;;; --- attribute validation: let the client frameworks through ---------------
;;; Spinneret validates attribute names against the HTML spec at MACROEXPANSION
;;; time and WARNs on anything it doesn't know ("HX-POST is not a valid attribute
;;; for <INPUT>"). Its escape hatch is a prefix list: any attribute starting with
;;; one of `spinneret:*unvalidated-attribute-prefixes*` is passed through
;;; unchecked. Hyperion is HTMX-first and ships Alpine/hyperscript-friendly
;;; examples, so we register those prefixes for every app that loads Hyperion.
;;; Because the check runs at macroexpansion time, the registration must happen
;;; when this file is COMPILED as well as when it is loaded -- hence eval-when;
;;; app files compile after hyperion is loaded, so they are covered too.

(eval-when (:compile-toplevel :load-toplevel :execute)

  (defparameter *client-attribute-prefixes*
    '("hx-"                ; HTMX core (recent Spinneret ships this; older ones don't)
      "ws-" "sse-"         ; HTMX extensions: websockets, server-sent events
      "x-"                 ; Alpine.js  (x-data, x-model, x-text, ...)
      "@"                  ; Alpine/Vue event shorthand (:@click.away)
      "_"                  ; _hyperscript
      "data-" "aria-")     ; already Spinneret defaults; listed so the set is explicit
    "Attribute-name prefixes Hyperion exempts from Spinneret's HTML validation.
Pushed onto SPINNERET:*UNVALIDATED-ATTRIBUTE-PREFIXES* when this file is compiled
and loaded. Add your own with ALLOW-ATTRIBUTE-PREFIX rather than editing this.")

  (defun allow-attribute-prefix (prefix)
    "Exempt attributes starting with PREFIX from Spinneret's attribute validation.
For client frameworks Hyperion doesn't ship with, e.g. (allow-attribute-prefix \"ng-\").
Matching is case-insensitive. Call it at compile time (inside EVAL-WHEN, or in a
file loaded before the templates) -- Spinneret validates while macroexpanding.
Returns the updated prefix list."
    (pushnew (string-downcase (string prefix))
             spinneret:*unvalidated-attribute-prefixes*
             :test #'equal))

  (mapc #'allow-attribute-prefix *client-attribute-prefixes*))

(defun swap-string (swap)
  "SWAP keyword -> the hx-swap value, via the typed Coalton renderer.
One of :inner-html :outer-html :before-begin :after-begin :before-end :after-end
:delete :none."
  (ecase swap
    (:inner-html   (coalton:coalton (htmx:swap->string htmx:InnerHTML)))
    (:outer-html   (coalton:coalton (htmx:swap->string htmx:OuterHTML)))
    (:before-begin (coalton:coalton (htmx:swap->string htmx:BeforeBegin)))
    (:after-begin  (coalton:coalton (htmx:swap->string htmx:AfterBegin)))
    (:before-end   (coalton:coalton (htmx:swap->string htmx:BeforeEnd)))
    (:after-end    (coalton:coalton (htmx:swap->string htmx:AfterEnd)))
    (:delete       (coalton:coalton (htmx:swap->string htmx:DeleteSwap)))
    (:none         (coalton:coalton (htmx:swap->string htmx:NoSwap)))))

(defun verb-attr (verb)
  "VERB keyword (:get :post :put :patch :delete) -> the hx-<verb> attribute name,
via the typed renderer."
  (ecase verb
    (:get    (coalton:coalton (htmx:verb->attr htmx:Get)))
    (:post   (coalton:coalton (htmx:verb->attr htmx:Post)))
    (:put    (coalton:coalton (htmx:verb->attr htmx:Put)))
    (:patch  (coalton:coalton (htmx:verb->attr htmx:Patch)))
    (:delete (coalton:coalton (htmx:verb->attr htmx:Delete)))))

(defun millis (n)
  "N milliseconds as an hx duration string (\"Nms\"), via the typed renderer."
  (htmx:render-millis n))

(defun seconds (n)
  "N seconds as an hx duration string (\"Ns\"), via the typed renderer."
  (htmx:render-seconds n))

(defun trigger-string (spec)
  "SPEC -> an hx-trigger value via the typed renderer. SPEC is :load, :revealed,
an event string, (:event NAME), (:every-ms N), or (:every-s N)."
  (etypecase spec
    (string spec)
    (keyword (ecase spec
               (:load     (coalton:coalton (htmx:trigger->string htmx:Load)))
               (:revealed (coalton:coalton (htmx:trigger->string htmx:Revealed)))))
    (cons (ecase (first spec)
            (:event    (second spec))
            (:every-ms (htmx:render-every-millis (second spec)))
            (:every-s  (htmx:render-every-seconds (second spec)))))))

(defun target-string (spec)
  "SPEC -> an hx-target value. :this -> \"this\"; a string selector -> itself."
  (if (eq spec :this)
      (coalton:coalton (htmx:target->string htmx:ThisElement))
      spec))

(defun oob (&optional swap target)
  "Value for hx-swap-oob, routing SWAP through the typed renderer.
  (oob)                     => \"true\"        (swap by matching id)
  (oob :inner-html)         => \"innerHTML\"
  (oob :inner-html \"#sel\")  => \"innerHTML:#sel\""
  (cond ((null swap) "true")
        (target (format nil "~A:~A" (swap-string swap) target))
        (t (swap-string swap))))
