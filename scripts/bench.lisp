;;;; bench.lisp --- what is Coalton's release mode actually worth? (pre-publication issue 98)
;;;;
;;;;   sbcl --script scripts/with-mode.lisp dev     scripts/bench.lisp
;;;;   sbcl --script scripts/with-mode.lisp release scripts/bench.lisp
;;;;   ... --iterations 400 --rows 2000
;;;;
;;;; Run it through with-mode.lisp, never directly: the mode is fixed before Coalton is
;;;; built, so a bare run measures whatever the ambient cache happens to hold.
;;;;
;;;; EVERY NUMBER THIS PRINTS STATES ITS MODE, and the mode is read from the RUNNING IMAGE
;;;; (`coalton-release-p`) rather than from COALTON_ENV. Those two can disagree -- the
;;;; variable is what was asked for, the predicate is what was built -- and a benchmark that
;;;; reports the request rather than the reality is precisely the failure pre-publication issue 98 was filed
;;;; over. If they disagree, this refuses to run.
;;;;
;;;; THE WORKLOAD is aion/csv/types:parse-rfc4180-rows -- a real RFC-4180 parser written as
;;;; a Coalton DFA. It is chosen because its inner loop is almost entirely ADT construction
;;;; and matching (CharClass, ParseState, Action, Step), which is exactly what the mode
;;;; changes: CLOS objects in development, frozen defstructs in release. A workload that
;;;; spent its time in arithmetic would show the mode's floor, not its ceiling.
;;;;
;;;; aion/csv:parse-string is timed on the same input as CONTEXT, not as a rival. It is a
;;;; different implementation (a stream DFA in plain CL, deliberately Coalton-free so the
;;;; portable core loads on bare SBCL/CCL/ECL/ABCL), so the pair does not measure "Coalton
;;;; versus CL" and must not be quoted that way. What it gives is a fixed reference point
;;;; that the mode cannot move, which makes it possible to see that a change between two
;;;; runs was the mode and not the machine.
;;;;
;;;; A SECOND WORKLOAD, deliberately of a different shape. aion/log/types:render-event-line
;;;; is the single entry point the CL logging facade calls -- every log line in the tree
;;;; goes through it -- and it is string building plus list traversal rather than the CSV
;;;; parser's dense state-machine churn. One workload cannot tell you what a mode is worth;
;;;; two of different shapes at least show whether the answer depends on the shape. Expect
;;;; a smaller multiple here, and report it whatever it is: a benchmark suite that only
;;;; keeps its most flattering case is an advertisement.
;;;;
;;;; A THIRD WORKLOAD, because it bears on a claim we have already published.
;;;; hyperion/path:path-matches? is Coalton and runs PER REQUEST in the router. The repo's
;;;; public performance story (README, ECOSYSTEM, docs/working-with-ai.md) quotes 44.00 ms
;;;; against 0.15 ms per request, a delayed-ACK finding from ADR-0011 -- and those numbers
;;;; were measured in development mode, like everything else here, without saying so.
;;;;
;;;; The 44 ms is a kernel-level stall and cannot care how Coalton represents an ADT. The
;;;; 0.15 ms is a different matter: it is small enough that a Coalton component could be a
;;;; visible fraction of it. Measuring the router in both modes says whether the published
;;;; number could move, WITHOUT restaging the whole HTTP benchmark -- measure the part that
;;;; can change and compare its magnitude to the claim.
;;;;
;;;; It also CHECKS THE WORK. A benchmark whose function returns NIL instantly is a very
;;;; fast benchmark of nothing, so both parsers must agree on the row and cell count before
;;;; anything is timed.

(require :asdf)
(require :uiop)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))

(defun arg-value (name default)
  "The positive integer following NAME on the command line, or DEFAULT.

A non-integer exits with a usage line, not a backtrace. This is a CLI script: `--iterations
all` is a typo, and answering a typo with an SBCL debugger dump tells the person who made it
nothing they can act on. PARSE-INTEGER without :JUNK-ALLOWED on purpose -- :junk-allowed
would read `200x` as 200 and silently benchmark something other than what was asked for.

Zero is rejected along with the unparseable: ITERATIONS is a divisor in BENCH, so 0 is not a
degenerate run, it is a division by zero several seconds after the mistake."
  (let ((tail (member name (uiop:command-line-arguments) :test #'string=)))
    (if (and tail (second tail))
        (let ((n (handler-case (parse-integer (second tail)) (error () nil))))
          (cond ((null n)
                 (format *error-output* "~&bench: ~A expects a positive integer -- got ~S~%"
                         name (second tail))
                 (format *error-output* "usage: bench.lisp [--iterations N] [--rows N]~%")
                 (uiop:quit 2))
                ((not (plusp n))
                 (format *error-output* "~&bench: ~A must be positive -- got ~D~%" name n)
                 (uiop:quit 2))
                (t n)))
        default)))

(defparameter *iterations* (arg-value "--iterations" 200))
(defparameter *rows* (arg-value "--rows" 1000))

(format t "~&loading aion/csv and aion/csv/types ...~%")
(finish-output)
(funcall (read-from-string "ql:quickload") '(:aion/csv :aion/csv/types :aion/log :hyperion) :silent t)

;;; --- the mode, from the image itself ---------------------------------------

(defparameter *release-p*
  (funcall (read-from-string "coalton-impl/settings:coalton-release-p")))

(defparameter *asked-for*
  (let ((v (uiop:getenv "COALTON_ENV")))
    (if (and v (string-equal v "release")) :release :development)))

(defparameter *mode* (if *release-p* :release :development))

(when (not (eq *mode* *asked-for*))
  (format *error-output*
          "~&bench: COALTON_ENV asked for ~(~a~) but the image was built ~(~a~).~%"
          *asked-for* *mode*)
  (format *error-output*
          "bench: that is the stale-fasl failure this script exists to refuse. Run it~%")
  (format *error-output*
          "bench: through scripts/with-mode.lisp, which gives each mode its own cache.~%")
  (uiop:quit 1))

;;; --- the input -------------------------------------------------------------

(defun make-csv (rows)
  "ROWS lines of five fields, one of them quoted and containing a comma and an escaped
quote -- so the parser actually visits its quoted-field states rather than the happy path."
  (with-output-to-string (s)
    (format s "id,name,note,qty,price~%")
    (dotimes (i rows)
      (format s "~D,name-~D,\"a, \"\"quoted\"\" note\",~D,~,2F~%"
              i i (mod i 97) (/ (mod i 1000) 7.0)))))

(defparameter *input* (make-csv *rows*))

;;; --- correctness before speed ----------------------------------------------

(defparameter *coalton-rows*
  (funcall (read-from-string "aion/csv/types:parse-rfc4180-rows") *input*))
(defparameter *cl-rows*
  (funcall (read-from-string "aion/csv:parse-string") *input*))

(defun row-count (rows) (length rows))
(defun cell-count (rows) (reduce #'+ rows :key #'length :initial-value 0))

(let ((cr (row-count *coalton-rows*)) (lr (row-count *cl-rows*))
      (cc (cell-count *coalton-rows*)) (lc (cell-count *cl-rows*)))
  (format t "~&input:  ~:D rows of CSV (~:D characters)~%" *rows* (length *input*))
  (format t "parsed: coalton ~:D rows / ~:D cells   cl ~:D rows / ~:D cells~%" cr cc lr lc)
  (when (or (zerop cr) (zerop cc))
    (format *error-output* "~&bench: the Coalton parser returned nothing -- there is no~%")
    (format *error-output* "bench: point timing it. Malformed input, or a broken build.~%")
    (uiop:quit 1))
  (unless (and (= cr lr) (= cc lc))
    (format *error-output* "~&bench: the two parsers DISAGREE (~D/~D rows, ~D/~D cells).~%"
            cr lr cc lc)
    (format *error-output* "bench: timing two functions that do different work is not a~%")
    (format *error-output* "bench: comparison. This is a conformance failure, report it.~%")
    (uiop:quit 1)))

;;; --- timing ----------------------------------------------------------------

(defmacro timing ((&key (repeat 1)) &body body)
  "Returns (values seconds bytes-consed), with the body run REPEAT times."
  `(let ((t0 (get-internal-real-time))
         (b0 (sb-ext:get-bytes-consed)))
     (dotimes (%i ,repeat) ,@body)
     (values (/ (float (- (get-internal-real-time) t0))
                internal-time-units-per-second)
             (- (sb-ext:get-bytes-consed) b0))))

(defun bench (label thunk iterations)
  ;; Warm up first: the first call through a Coalton entry point pays for whatever the
  ;; image has deferred, and folding that into the first iteration makes a short run read
  ;; as slower than a long one for reasons that are not the code.
  (dotimes (i 3) (funcall thunk))
  (sb-ext:gc :full t)
  (multiple-value-bind (secs bytes) (timing (:repeat iterations) (funcall thunk))
    ;; The MODE is on the line, not only in the section header above it. A header scopes a
    ;; number until someone copies ONE line into an issue or a doc, at which point the
    ;; scope is gone and the number is unattributed again -- which is precisely the
    ;; ambiguity pre-publication issue 98 existed to remove ("every performance number we have is currently
    ;; meaningless"). A measurement that can be quoted without its mode is not fixed yet.
    (format t "  [~(~a~)] ~a~40t~8,3F s total   ~9,3F ms/op   ~9:D bytes/op~%"
            *mode* label secs (* 1000 (/ secs iterations)) (round bytes iterations))
    (list :label label :seconds secs :ms-per-op (* 1000 (/ secs iterations))
          :bytes-per-op (round bytes iterations))))

(format t "~%========== coalton ~(~a~) mode ==========~%" *mode*)
(format t "iterations: ~:D~%~%" *iterations*)

(defparameter *fields*
  (let ((mk-str (read-from-string "aion/log/types:mk-field-string"))
        (mk-raw (read-from-string "aion/log/types:mk-field-raw")))
    (list (funcall mk-str "request_id" "01J8Z2K5Q3F7V9WNTQX4YB6CDE")
          (funcall mk-str "route" "/api/v1/things/42")
          (funcall mk-raw "rows" "3")
          (funcall mk-raw "ms" "41")
          (funcall mk-str "backend" "postgres"))))

(defparameter *rendered*
  (funcall (read-from-string "aion/log/types:render-event-line")
           "json" "info" "db" "query finished" "2026-08-25T12:00:00Z" *fields*))

(when (or (null *rendered*) (zerop (length *rendered*)))
  (format *error-output* "~&bench: render-event-line produced nothing to measure.~%")
  (uiop:quit 1))
(format t "log line: ~D characters~%" (length *rendered*))

(defparameter *pattern*
  (funcall (read-from-string "hyperion/path:parse-pattern") "/api/v1/things/:id/parts/:part"))

(defparameter *match-p*
  (funcall (read-from-string "hyperion/path:path-matches?")
           *pattern* "/api/v1/things/42/parts/7"))

(unless *match-p*
  (format *error-output* "~&bench: the router did not match its own example path --~%")
  (format *error-output* "bench: timing a matcher that never matches measures the reject path.~%")
  (uiop:quit 1))

(let* ((parse-coalton (read-from-string "aion/csv/types:parse-rfc4180-rows"))
       (parse-cl (read-from-string "aion/csv:parse-string"))
       (render (read-from-string "aion/log/types:render-event-line"))
       (coalton (bench "csv: coalton DFA" (lambda () (funcall parse-coalton *input*)) *iterations*))
       (cl (bench "csv: cl DFA (reference)" (lambda () (funcall parse-cl *input*)) *iterations*))
       ;; Scaled up: one log line is microseconds, so at the CSV iteration count the timer
       ;; resolution would be a bigger term than the thing being measured.
       (log-iters (* *iterations* 500))
       (matches (read-from-string "hyperion/path:path-matches?"))
       (router (bench "router: path-matches?"
                      (lambda () (funcall matches *pattern* "/api/v1/things/42/parts/7"))
                      (* *iterations* 500)))
       (logline (bench "log: render-event-line"
                       (lambda () (funcall render "json" "info" "db" "query finished"
                                           "2026-08-25T12:00:00Z" *fields*))
                       log-iters)))
  (format t "~%mode: ~(~a~)   (coalton-release-p = ~a)~%" *mode* *release-p*)
  ;; One machine-readable line, so a CI step or a second run can diff two modes without
  ;; anyone re-typing a number out of a terminal into a document.
  (format t "BENCH ~(~a~) csv-coalton-ms=~,4F csv-coalton-bytes=~D csv-cl-ms=~,4F csv-cl-bytes=~D log-ms=~,6F log-bytes=~D iterations=~D rows=~D~%"
          *mode*
          (getf coalton :ms-per-op) (getf coalton :bytes-per-op)
          (getf cl :ms-per-op) (getf cl :bytes-per-op)
          (getf logline :ms-per-op) (getf logline :bytes-per-op)
          *iterations* *rows*)
  (format t "BENCH ~(~a~) router-ms=~,6F router-bytes=~D~%"
          *mode* (getf router :ms-per-op) (getf router :bytes-per-op)))
(uiop:quit 0)
