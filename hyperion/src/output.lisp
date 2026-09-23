;;;; output.lisp --- one place to configure rendered-output style (HTML + JS).
;;;;
;;;; Both Spinneret (HTML) and Parenscript (JS) key their formatting off dynamic
;;;; variables. Hyperion funnels all of them through a single style knob so a
;;;; call site -- or the whole app -- picks pretty vs compact once, and the two
;;;; renderers always agree.
;;;;
;;;; Scope note: no optimization/minification lives here (see
;;;; docs/research/live-repl-and-dynamic-compilation.md and the vision doc).
;;;; :compact means whitespace-minimal, single-line output -- not a true
;;;; minifier. A real CL-side minifier, if we ever want one, becomes a third
;;;; OUTPUT-STYLE member; call sites won't change.

(in-package #:hyperion/output)

(deftype output-style ()
  "How rendered HTML/JS is formatted. An enum rather than a boolean so a future
:minified (or :obfuscated) style slots in without disturbing call sites."
  '(member :pretty :compact))

(defparameter *output-style* :pretty
  "Default output style for HTML (Spinneret) and JS (Parenscript).

:pretty  -- indented, human-readable; use in :dev and the compile-error overlay.
:compact -- single-line, whitespace-minimal; use for production responses.

Bind per-call with WITH-OUTPUT-STYLE, or SETF once at startup (e.g. from the
server's :dev/:prod profile).")

(defparameter *pretty-indent* 2
  "Indent width, in spaces, for pretty *JS* output. Matches Hyperion's 2-space
convention (Parenscript's own default is 4). Note: Spinneret's :human HTML style
manages its own indentation and exposes no width knob, so this affects JS only.")

(defparameter *fill-column* 80
  "Column at which Spinneret wraps text runs in :pretty mode (HTML only).")

(declaim (ftype (function (&optional output-style) t) prettyp))
(defun prettyp (&optional (style *output-style*))
  "True when STYLE asks for human-readable output."
  (eq style :pretty))

(defmacro with-output-style ((&optional (style '*output-style*)) &body body)
  "Evaluate BODY with every Spinneret and Parenscript formatting variable bound
to match STYLE (defaulting to *OUTPUT-STYLE*). This is the single point that
keeps the HTML and JS renderers in agreement; render inside it and both obey the
same knob.

  (with-output-style (:compact)
    (spinneret:with-html-string (:p \"hi\")))   ; => \"<p>hi</p>\""
  (let ((s (gensym "STYLE"))
        (pretty (gensym "PRETTY")))
    `(let* ((,s ,style)
            (,pretty (prettyp ,s)))
       ;; CL's *print-pretty* is the master switch Spinneret and Parenscript
       ;; both consult; the rest tune the pretty path (ignored when compact).
       (let ((cl:*print-pretty*              ,pretty)
             (ps:*ps-print-pretty*           ,pretty)
             (ps:*indent-num-spaces*         *pretty-indent*)
             (spin:*html-style*              :human)
             (spin:*fill-column*             *fill-column*))
         ,@body))))

(defmacro html-string ((&optional (style '*output-style*)) &body body)
  "Render Spinneret BODY to an HTML string in STYLE (default *OUTPUT-STYLE*)."
  `(with-output-style (,style)
     (spin:with-html-string ,@body)))

(defun js-string (&rest forms)
  "Compile Parenscript FORMS to a JS string in the current *OUTPUT-STYLE*.
Wrap the call in WITH-OUTPUT-STYLE to override per-call:
  (with-output-style (:compact) (js-string '(defun f (x) (return (* x x)))))"
  (with-output-style ()
    (apply #'ps:ps* forms)))
