;;;; log.lisp --- the aion/log facade over log4cl.

(in-package #:aion/log)

;;; --- state ----------------------------------------------------------------

(defvar *layout* :pretty
  "How a log line renders: :PRETTY (human, for dev/SLIME) or :JSON (one line per event,
for staging/prod stdout capture). Set by SETUP; overridable at runtime.")

(defvar *context* '()
  "Ambient structured fields (a plist with keyword keys) merged into every log event in
dynamic scope. Bound by WITH-CONTEXT -- e.g. request-id, user, community, env.

BOUND WITH LET, SO IT IS PER-THREAD. Work handed to another thread reads the global value,
which is the empty list, and every field the seam established is missing from that thread's
lines with nothing reporting it. `aion/dynamic' is how a spawn site carries this across --
see the registration below.")

;; Declared inheritable so a spawn site that continues the current unit of work can carry
;; the ambient fields onto the child (#158). Registration alone moves nothing: the value
;; crosses only where a caller captures it. The sweep in aion's suite is what keeps that
;; honest, by failing on a thread-spawn site that has neither carried the bindings nor said
;; why it does not.
(aion/dynamic:register-inheritable '*context*)

;;; --- rendering (the typed core owns the shape; this shell supplies the untyped world) --
;;;
;;; RENDER used to be four CL functions: an ECASE over the layout keyword and two hand-
;;; written emitters. The shape now lives in aion/log/types (Coalton) -- Level is ordered,
;;; Layout is exhaustive, and an Event is a value. What is left here is exactly the part
;;; that must be CL: reading the clock, and deciding which of CL's open-ended type universe
;;; each field value is. That decision is made ONCE per field, at this boundary, and handed
;;; across as a typed Field.

(defun %name (x)
  (etypecase x
    (string x)
    (symbol (string-downcase (symbol-name x)))))

(defun %iso-now ()
  "Current time as an ISO-8601 UTC string. Dependency-free (decode-universal-time).
Stays in CL: reading a clock is IO, and the typed core does none."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))

(defun %field (key value)
  "One CL key/value pair as a typed Field.

This is the decode point. JSON has four scalar shapes and CL has thousands of types, so
something has to choose -- and choosing here, once per field, is what lets the renderer be
total. A real number and a boolean become JSON literals; everything else becomes a string,
including symbols and keywords (downcased, as before) and any object at all via its printed
representation, except a condition, which becomes its type (CONDITION-TYPE), never its report.
That rule is kept here so that it does not depend on every caller remembering it: a report can
quote outside data (#1013). The result is opaque to this file: built by Coalton, handed
straight back to it, never inspected."
  (let ((k (%name key)))
    (typecase value
      (null    (types:mk-field-raw k "false"))
      ((member t) (types:mk-field-raw k "true"))
      (integer (types:mk-field-raw k (princ-to-string value)))
      ;; A float is printed by CL, which can emit 1.0d0 or 1/3 -- neither is JSON. Only
      ;; forms JSON accepts pass through raw; the rest fall back to a string, which is
      ;; lossless for a reader and never produces a malformed line.
      (real    (let ((printed (format nil "~F" value)))
                 (if (every (lambda (c) (or (digit-char-p c) (member c '(#\- #\.)))) printed)
                     (types:mk-field-raw k printed)
                     (types:mk-field-string k (princ-to-string value)))))
      (string  (types:mk-field-string k value))
      (symbol  (types:mk-field-string k (string-downcase (symbol-name value))))
      (condition (types:mk-field-string k (condition-type value)))
      (t       (types:mk-field-string k (princ-to-string value))))))

(defun %fields (extra)
  "The merged field plist for an event: per-call EXTRA first, then ambient *CONTEXT*, as a
list of typed Fields. Order carries the precedence -- the typed core keeps the first
occurrence of each key, so a per-call field wins over an ambient one, and neither can
displace a core key. NIL-valued entries are dropped here, preserving the facade's rule that
a nil field is absent rather than false."
  (loop for (k v) on (append extra *context*) by #'cddr
        when v collect (%field k v)))

(defun render (level cat message fields)
  "The full log line for an event under the current *LAYOUT*. Called only when the level is
enabled (the level macros guard it via log4cl), so its cost is paid only for emitted events.

Every argument crosses into Coalton as a promised representation -- strings and a list of
opaque Fields -- and a String comes back. Coalton checks the strings on entry but not the
list's elements, so the list is checked here (#110)."
  (types:render-event-line (%name *layout*)
                           (%name level)
                           cat
                           (princ-to-string message)
                           (%iso-now)
                           (boundary:check-elements (%fields fields) 'types:field
                                                    :function 'types:render-event-line
                                                    :argument 'fields)))

;;; --- the leveled macros (thin wrappers over log4cl's, preserving its gating +
;;;     source-derived category) ---------------------------------------------

;;; Each wraps the matching log4cl macro, so log4cl handles gating (RENDER runs only when the
;;; level is enabled) and derives the category from the call-site package (captured here at
;;; macroexpansion). Explicit rather than macrolet-generated -- six near-identical forms are
;;; clearer than nested backquote.

(defmacro trace (message &rest fields)
  "Log MESSAGE at trace with structured FIELDS (a keyword/value plist)."
  `(lm:trace "~A" (render :trace ,(package-name *package*) ,message (list ,@fields))))

(defmacro debug (message &rest fields)
  "Log MESSAGE at debug with structured FIELDS (a keyword/value plist)."
  `(lm:debug "~A" (render :debug ,(package-name *package*) ,message (list ,@fields))))

(defmacro info (message &rest fields)
  "Log MESSAGE at info with structured FIELDS (a keyword/value plist)."
  `(lm:info "~A" (render :info ,(package-name *package*) ,message (list ,@fields))))

(defmacro warn (message &rest fields)
  "Log MESSAGE at warn with structured FIELDS (a keyword/value plist)."
  `(lm:warn "~A" (render :warn ,(package-name *package*) ,message (list ,@fields))))

(defmacro error (message &rest fields)
  "Log MESSAGE at error with structured FIELDS (a keyword/value plist)."
  `(lm:error "~A" (render :error ,(package-name *package*) ,message (list ,@fields))))

(defmacro fatal (message &rest fields)
  "Log MESSAGE at fatal with structured FIELDS (a keyword/value plist)."
  `(lm:fatal "~A" (render :fatal ,(package-name *package*) ,message (list ,@fields))))

(defmacro with-context ((&rest plist) &body body)
  "Run BODY with the keyword/value pairs in PLIST added to the ambient logging *CONTEXT*
(they appear as structured fields on every event logged within)."
  `(let ((*context* (list* ,@plist *context*))) ,@body))

;;; --- errors with backtraces -----------------------------------------------

(defvar *log-condition-details* nil
  "When true, EXCEPTION also writes the condition's report, as `error`, and a backtrace with
each frame's arguments. NIL by default, and nothing sets it: an app turns it on for a
development run, and the DEBUG level does not imply it (#1013).

It is off because both can hold outside data. A database driver's report can quote row values,
and a frame's printed arguments can hold a request body, so with them on, an unhandled error
can put an app's client data in its log, which AGENTS.md and docs/logging.md forbid: log counts,
ids and durations, never payloads.")

(defparameter +backtrace-frames+ 40 "The most frames EXCEPTION's backtrace holds.")

(defun %qualified-name (symbol)
  "SYMBOL as PACKAGE::NAME, or its name alone when it has no package."
  (let ((package (symbol-package symbol)))
    (if package
        (format nil "~A::~A" (package-name package) (symbol-name symbol))
        (symbol-name symbol))))

(defun condition-type (condition)
  "CONDITION's type, fully qualified, such as \"SB-INT::SIMPLE-PROGRAM-ERROR\": what a log line
records about a condition in place of its report, which can quote outside data (#1013).

    (log:warn \"the call failed\" :condition (log:condition-type e))"
  (%qualified-name (class-name (class-of condition))))

(defun %frame-names ()
  "The names of the innermost +BACKTRACE-FRAMES+ frames, one per line, with no arguments: the
name of each frame's function, which comes from the code, never from the values it was called
with."
  (handler-case
      (with-output-to-string (s)
        #+sbcl
        (let ((*package* (find-package '#:keyword))
              (*print-length* 8) (*print-level* 4) (*print-readably* nil))
          (sb-debug:map-backtrace
           (lambda (frame)
             (prin1 (sb-di:debug-fun-name (sb-di:frame-debug-fun frame)) s)
             (terpri s))
           :count +backtrace-frames+)))
    ;; cl:error -- `error` is shadowed in this package (it's our log macro)
    (cl:error () "")))

(defun %backtrace-with-arguments (condition)
  "CONDITION's type and report, then a backtrace that prints each frame's arguments. Written only
under *LOG-CONDITION-DETAILS*."
  (handler-case
      (with-output-to-string (s)
        (format s "~A: ~A" (type-of condition) condition)
        #+sbcl (progn (terpri s) (sb-debug:print-backtrace :stream s :count +backtrace-frames+)))
    (cl:error () (princ-to-string condition))))

(defun %exception-fields (condition)
  "The fields EXCEPTION adds for CONDITION: `error-type` and a backtrace of frame names, and,
only under *LOG-CONDITION-DETAILS*, `error`, the report, with the backtrace's frame arguments."
  (if *log-condition-details*
      (list :error-type (condition-type condition)
            :error (handler-case (princ-to-string condition)
                     (cl:error () "(the condition's report could not be printed)"))
            :backtrace (%backtrace-with-arguments condition))
      (list :error-type (condition-type condition)
            :backtrace (%frame-names))))

(defmacro exception (condition &optional (message "unhandled condition") &rest fields)
  "Log CONDITION at ERROR with MESSAGE, structured FIELDS, and fields derived from CONDITION:
`error-type`, its fully qualified type name, and `backtrace`, the names of up to 40 frames with
no arguments. The condition's report is not written, because it can quote outside data; with
*LOG-CONDITION-DETAILS* true, a development setting that is off by default, `error`, the report,
is written too, and the backtrace prints each frame's arguments (#1013). Pass a live condition."
  (let ((cat (package-name *package*))
        (c (gensym "COND")))
    `(let* ((,c ,condition)
            (*context* (append (%exception-fields ,c) *context*)))
       (lm:error "~A" (render :error ,cat ,message (list ,@fields))))))

;;; --- configuration --------------------------------------------------------

(defun level! (level &optional category)
  "Set the log LEVEL (a keyword: :trace :debug :info :warn :error :fatal :off) at runtime,
for CATEGORY (a log4cl category designator) or the root logger. Also doable live from the
REPL via log4cl (e.g. (log:config :debug)).

Signals on a level that does not exist. This is the payoff of Level being a type: a typo'd
:warm used to be accepted here and then silently never match, so the logger simply went
quiet and the misspelling was invisible until someone went looking for missing output."
  (unless (or (eq level :off) (types:valid-level-name? (%name level)))
    (cl:error "aion/log: ~S is not a log level (trace debug info warn error fatal off)" level))
  (if category
      (l4:log-config category level)
      (l4:log-config level))
  level)

(defun setup (&key (env :dev) (level :info) (stream *standard-output*))
  "Configure logging for ENV. Installs a single appender to STREAM (stdout by default, which
App Platform captures) and selects the layout: :JSON for :prod/:production/:staging, :PRETTY
otherwise. LEVEL is the initial root level. Idempotent -- clears existing appenders first.
Returns the chosen *LAYOUT*."
  (unless (or (eq level :off) (types:valid-level-name? (%name level)))
    (cl:error "aion/log: ~S is not a log level (trace debug info warn error fatal off)" level))
  (setf *layout* (if (member env '(:prod :production :staging)) :json :pretty))
  (l4:remove-all-appenders l4:*root-logger*)
  (l4:add-appender l4:*root-logger*
                   (make-instance 'l4:fixed-stream-appender
                                  :stream stream
                                  :layout (make-instance 'l4:pattern-layout
                                                         :conversion-pattern "%m%n")))
  (l4:log-config level)
  *layout*)
