;;;; js.lisp --- client JS authored in Lisp, compiled with Parenscript (no Node).
;;;;
;;;; The constitution's dogfood mandate: hand-written interaction JS becomes
;;;; Parenscript. DEV-RELOAD-JS is the hot-reload poller + compile-error overlay
;;;; (was praxeon's *dev-reload-js* raw string). The three interaction helpers are
;;;; the generic, selector-parametrized distillation of praxeon's *chat-js*
;;;; (auto-scroll, auto-grow textarea, Enter-to-send) -- domain-neutral building
;;;; blocks any app composes. Everything compiles through hyperion/output:js-string
;;;; so it honors *output-style* (pretty in dev, compact in prod).
;;;;
;;;; Emitted JS is inlined via Spinneret (:raw ...); it must contain no literal
;;;; < or > (which would break a <script> element). The sources below use no
;;;; comparison operators, so the compiled output is free of both. (&& -> "&&" is
;;;; fine inside a script.)

(in-package #:hyperion/js)

(defparameter *dev-reload-interval-ms* 2000
  "How often (ms) the dev poller checks the reload epoch and compile-error. Two seconds:
the poll exists to notice a recompile you just triggered, and the extra second is
imperceptible against the compile itself while halving the background traffic.")

(defparameter *dev-error-element-id* "hyperion-dev-error"
  "The id of the fixed compile-error overlay the dev poller creates.")

(defparameter *dev-overlay-css*
  (concatenate 'string
    "display:none;position:fixed;left:0;right:0;bottom:0;max-height:45vh;"
    "overflow:auto;margin:0;padding:1rem;background:#b00020;color:#fff;"
    "font:13px/1.4 monospace;white-space:pre-wrap;z-index:99999;"
    "box-shadow:0 -2px 10px rgba(0,0,0,.4)")
  "cssText for the red compile-error overlay. No < or > (script-safe).")

(defun dev-reload-js (&key (epoch-url "/api/reload-epoch")
                           (error-url "/api/dev-error")
                           (interval *dev-reload-interval-ms*)
                           (error-id *dev-error-element-id*))
  "Compiled JS for the hot-reload poller: every INTERVAL ms it (1) fetches the
reload epoch and reloads the page when it changes, and (2) fetches the dev error
and shows/hides a red overlay. Cache-buster `?_=`+Date.now() is essential or the
browser caches the epoch. Inlined via (:raw ...); see the file header."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((epoch nil) (box nil))
         (labels ((overlay ()
                    (unless box
                      (setf box (chain document (create-element "div")))
                      (setf (@ box id) ,error-id)
                      (setf (@ box style css-text) ,*dev-overlay-css*)
                      (chain document body (append-child box)))
                    box))
           (set-interval
            (lambda ()
              (chain (fetch (+ ,(concatenate 'string epoch-url "?_=")
                               (chain -date (now))))
                     (then (lambda (r) (chain r (text))))
                     (then (lambda (tx)
                             (if (eq epoch nil)
                                 (setf epoch tx)
                                 (when (not (equal tx epoch))
                                   (chain location (reload))))))
                     (catch (lambda () nil)))
              (chain (fetch (+ ,(concatenate 'string error-url "?_=")
                               (chain -date (now))))
                     (then (lambda (r) (chain r (text))))
                     (then (lambda (tx)
                             (let ((b (overlay)))
                               (if (and tx (@ tx length))
                                   (progn (setf (@ b text-content) tx)
                                          (setf (@ b style display) "block"))
                                   (setf (@ b style display) "none")))))
                     (catch (lambda () nil)))
              nil)
            ,interval)))))))

(defun stick-to-bottom-js (container &key (threshold 40))
  "Compiled JS: keep the CONTAINER (a CSS selector) scrolled to the bottom as new
content arrives (a MutationObserver), and on page load -- but only while the reader
is already within THRESHOLD px of the bottom. Scrolling up to re-read something
detaches the stick; scrolling back down re-attaches it. Unconditional auto-scroll is
the naive version of this helper, and it yanks the view away from whatever someone
went back to read. CONTAINER is required -- the framework makes no assumption about
the app's markup."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((el (chain document (query-selector ,container))))
         (when el
           (let* ((stuck t)
                  (to-bottom (lambda () (setf (@ el scroll-top) (@ el scroll-height)))))
             ;; Track the position on SCROLL rather than measuring it in the observer:
             ;; a MutationObserver fires AFTER the DOM changed, by which point the
             ;; pre-append position is gone. Appending content fires no scroll event,
             ;; so the flag still describes where the reader left the viewport.
             ;; The distance test avoids < and > deliberately -- see the file header.
             (chain el (add-event-listener "scroll"
                         (lambda ()
                           (setf stuck
                                 (not (eq 1 (chain -math
                                                   (sign (- (- (@ el scroll-height)
                                                               (+ (@ el scroll-top)
                                                                  (@ el client-height)))
                                                            ,threshold)))))))
                         (create "passive" t)))
             ;; NB: MutationObserver needs the key "childList" (camelCase). PS's
             ;; `create` does not camelCase keys, so pass string keys verbatim.
             (chain (new (-mutation-observer (lambda () (when stuck (funcall to-bottom)))))
                    (observe el (create "childList" t "subtree" t)))
             (chain window (add-event-listener "load" to-bottom)))))))))

(defun autogrow-textarea-js (textarea &key (max-vh 0.4))
  "Compiled JS: make TEXTAREA (a CSS selector) auto-grow with its content, up to
MAX-VH of the viewport height. TEXTAREA is required."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((ta (chain document (query-selector ,textarea))))
         (when ta
           (let ((grow (lambda ()
                         (setf (@ ta style height) "auto")
                         (setf (@ ta style height)
                               (+ (chain -math
                                         (min (@ ta scroll-height)
                                              (chain -math (floor (* (@ window inner-height)
                                                                     ,max-vh)))))
                                  "px")))))
             (chain ta (add-event-listener "input" grow)))))))))

(defun enter-submits-js (textarea)
  "Compiled JS: in TEXTAREA (a CSS selector), Enter submits the form and
Shift+Enter inserts a newline; after the form's OWN submit, reset height and
refocus. The reset listener is bound to the textarea's FORM, not document.body, so
background htmx requests (e.g. a periodic progress poll) do NOT collapse the box
while you're typing -- the auto-grown height stays sticky until you send."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((ta (chain document (query-selector ,textarea))))
         (when ta
           (chain ta (add-event-listener "keydown"
                       (lambda (e)
                         (when (and (equal (@ e key) "Enter") (not (@ e shift-key)))
                           (chain e (prevent-default))
                           (when (@ ta form) (chain ta form (request-submit)))))))
           ;; Scope the height reset to this form's requests only (not every htmx
           ;; request on the page) so a background poll can't shrink the box.
           (when (@ ta form)
             (chain ta form
                    (add-event-listener "htmx:afterRequest"
                      (lambda ()
                        (set-timeout (lambda ()
                                       (setf (@ ta style height) "auto")
                                       (chain ta (focus)))
                                     0)))))))))))

(defun sticky-solidify-js (&key (selector ".is-sticky-solidify")
                                (scrolled-class "is-scrolled")
                                (threshold 24))
  "Compiled JS: the transparent-until-scrolled sticky-header pattern for landing
pages. The element matching SELECTOR -- a header that sits transparent over a hero --
gets SCROLLED-CLASS toggled once the page scrolls past THRESHOLD px, so the app's CSS
can fade it into a solid, still-pinned bar (and back). Runs once on load, then on
scroll (passive). No-op when nothing matches. SELECTOR / SCROLLED-CLASS / THRESHOLD
are the app's to choose; the framework only wires the listener -- the look is CSS."
  (out:js-string
   `(funcall
     (lambda ()
       (let ((el (chain document (query-selector ,selector))))
         (when el
           (let ((on-scroll (lambda ()
                              (chain el class-list
                                     (toggle ,scrolled-class
                                             (> (@ window scroll-y) ,threshold))))))
             (funcall on-scroll)
             (chain window (add-event-listener "scroll" on-scroll
                                               (create "passive" t))))))))))
