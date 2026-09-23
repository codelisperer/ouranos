;;;; packages.lisp --- aion/csv package.
;;;;
;;;; aion/csv is the CSV face of Aion: a backend-neutral protocol (dialects,
;;;; row streams, reducing entry points) plus the `portable` backend -- a pure-CL
;;;; scalar-DFA reader/writer with zero external dependencies. It is the always-
;;;; available default and the conformance oracle every faster backend (sb-simd,
;;;; zsv, duckdb) must agree with. See docs/csv-design.md for the full design.
;;;;
;;;; No Coalton dependency here on purpose: the portable core stays loadable on
;;;; bare SBCL/CCL/ECL/ABCL with no toolchain. Native muscle is opt-in, in
;;;; separate systems.

(cl:defpackage #:aion/csv
  (:use #:cl)
  (:documentation "Backend-neutral CSV for Aion: dialects, a scalar-DFA reader/writer,
and reducible row streams. The dependency-free `portable` backend.")
  (:export
   ;; dialect (policy as an immutable value)
   #:dialect #:make-dialect #:dialect-p #:copy-dialect #:dialect-with
   #:dialect-delimiter #:dialect-quote #:dialect-escape #:dialect-comment
   #:dialect-trim #:dialect-skip-blank-lines #:dialect-newline #:dialect-quoting
   #:+rfc4180+ #:+excel+ #:+unix+ #:+tsv+ #:+pipe+
   ;; conditions
   #:csv-error #:csv-parse-error
   #:csv-error-line #:csv-error-column #:csv-error-message
   ;; reduced protocol (foreshadows aion/xform)
   #:reduced #:reduced-p #:unreduce #:ensure-reduced
   ;; reader
   #:reader #:make-reader #:reader-line #:reader-column #:reader-dialect
   #:read-row #:map-rows #:do-rows #:fold-rows #:read-all
   #:parse-string #:read-file #:with-input #:call-with-input
   ;; writer
   #:field->string #:needs-quoting-p #:render-field
   #:write-row #:write-rows #:render-string #:write-file))
