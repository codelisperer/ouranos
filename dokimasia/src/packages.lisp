;;;; packages.lisp --- the package of dokimasia (#1028, dokimasia ADR-0001).
;;;;
;;;; DOKIMASIA is the CL shell: screens, cases and suites as data, the targets an app runs
;;;; against, the steps run in a headless browser through aion/cdp, the checks made after every
;;;; step, the report, and one FiveAM test per case and row. DOKIMASIA/CORE decides each row's
;;;; verdict.

(cl:defpackage #:dokimasia
  (:use #:cl)
  (:local-nicknames (#:core #:dokimasia/core)
                    (#:cdp #:aion/cdp)
                    (#:boundary #:aion/boundary)
                    (#:sexp #:aion/sexp)
                    (#:csv #:aion/csv)
                    (#:secret #:aion/secret)
                    (#:log #:aion/log)
                    (#:jzon #:com.inuoe.jzon))
  (:documentation "A data-driven acceptance-test harness for any app that runs in a browser
(#1028). See dokimasia/README.md.")
  (:export
   ;; definitions
   #:define-screen #:define-case #:define-suite #:define-probe
   #:find-screen #:find-case #:find-suite #:invalid-definition #:invalid-definition-reason
   ;; targets
   #:target #:url-target #:process-target
   #:target-start #:target-stop #:target-base-url #:target-users #:target-runs-local-probes-p
   #:target-settle #:target-prepare-page #:target-sign-in
   ;; running
   #:run #:*default-out* #:+viewports+
   #:*settle-timeout* #:*step-timeout* #:*quiet-period* #:*audit-impact* #:*audit-timeout*
   ;; the `acceptance' target of dokimasia/cons.lisp
   #:run-from-command-line #:command-line-exit-code #:parse-viewports #:parse-schemes
   #:command-line-error #:command-line-error-reason
   ;; for a settle check or a probe written outside this package
   #:row-page #:row-base-url #:row-target #:row-user #:*row*))

(cl:defpackage #:dokimasia/generated
  (:use)
  (:documentation "Where DOKIMASIA:RUN names the FiveAM suite and tests it makes for a suite's
cases and rows. Nothing else is interned here."))
