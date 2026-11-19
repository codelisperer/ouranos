;;;; audit.lisp --- the :audit step: axe-core run in the page once for each colour scheme (#1028,
;;;; dokimasia ADR-0001, point 2, "Accessibility").
;;;;
;;;; axe-core is vendored in dokimasia/vendor/ and pinned in dokimasia/vendor/ASSETS.pin. Its
;;;; text is read when this file is compiled and kept in the fasl, so a run never reads the source
;;;; tree for it, and a dumped image carries it. The .asd lists the vendored file before this one,
;;;; so a new axe.min.js recompiles this file. scripts/check-pins.lisp checks the file on disk
;;;; against the pin, and dokimasia's tests check the text compiled into the image against it.

(in-package #:dokimasia)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %vendored-text (relative)
    "The UTF-8 text of RELATIVE, a file of the dokimasia system, read when this is compiled."
    (with-open-file (in (asdf:system-relative-pathname "dokimasia" relative)
                        :element-type '(unsigned-byte 8))
      (let* ((octets (make-array (file-length in) :element-type '(unsigned-byte 8)))
             (n (read-sequence octets in)))
        (sb-ext:octets-to-string octets :end n :external-format :utf-8)))))

(defmacro %embed-text (relative)
  "RELATIVE's text as a literal string, so it lands in the fasl."
  (%vendored-text relative))

(defparameter +axe-source+ (%embed-text "vendor/axe.min.js")
  "The text of dokimasia/vendor/axe.min.js, axe-core as upstream released it.")

(defparameter +impacts+ '(:minor :moderate :serious :critical)
  "axe-core's impact levels, from the least severe to the most.")

(defvar *audit-impact* :serious
  "The impact level at or above which an :AUDIT step fails when the step names none.")

(defvar *audit-timeout* 30
  "Seconds an :AUDIT step waits for axe-core to check the page, for each colour scheme, when the
step gives no :TIMEOUT.")

(defun %impact-rank (impact)
  "IMPACT's position in +IMPACTS+, or -1 for an impact axe-core did not report."
  (or (position impact +impacts+ :test #'string-equal) -1))

(defun %load-axe (page timeout)
  "Load axe-core into PAGE unless it is there already. Returns axe-core's version."
  (flet ((version ()
           (cdp:evaluate page "(typeof window.axe === 'object' && window.axe && window.axe.version) || null"
                         :timeout timeout)))
    (or (version)
        (progn (cdp:evaluate page +axe-source+ :timeout timeout)
               (version))
        (%fail "axe-core could not be loaded into the page"))))

(defun %axe-violations (page ignore timeout)
  "Run axe-core over PAGE's document with the rules in IGNORE turned off. Returns a list of plists
(:id :impact :help :count :target), one per rule that found a violation."
  (let* ((json (cdp:evaluate
                page
                (format nil "(ignore => axe.run(document, {resultTypes: ['violations'], rules: Object.fromEntries(ignore.map(id => [id, {enabled: false}]))}).then(r => JSON.stringify(r.violations.map(v => ({id: v.id, impact: v.impact || '', help: v.help, count: v.nodes.length, target: v.nodes.length ? String(v.nodes[0].target) : ''})))))(~A)"
                        (jzon:stringify (coerce ignore 'vector)))
                :timeout timeout))
         (parsed (jzon:parse json)))
    (loop for v across parsed
          collect (list :id (gethash "id" v) :impact (gethash "impact" v) :help (gethash "help" v)
                        :count (gethash "count" v) :target (gethash "target" v)))))

(defun %audit (args)
  "Run axe-core in the row's page once for each colour scheme of the run, and fail when any rule
finds a violation at or above the step's :IMPACT."
  (destructuring-bind (&key (impact *audit-impact*) ignore timeout) args
    (let* ((ctx *run*) (page (row-page *row*))
           (timeout (or timeout *audit-timeout*))
           (floor (%impact-rank impact))
           (version (%load-axe page timeout))
           (found '()))
      ;; Transitions are off for the whole step, so axe judges each scheme's colours at rest
      ;; rather than part way from the other scheme's (#1288).
      (%call-still
       (lambda ()
         (unwind-protect
              (dolist (scheme (run-context-schemes ctx))
                (cdp:emulate-color-scheme page scheme :timeout *step-timeout*)
                (%next-frame)
                (dolist (v (%axe-violations page ignore timeout))
                  (when (>= (%impact-rank (getf v :impact)) floor)
                    (push (format nil "~(~A~): ~A (~A, ~D element~:P, first at ~A): ~A"
                                  scheme (getf v :id) (getf v :impact) (getf v :count)
                                  (getf v :target) (getf v :help))
                          found))))
           (cdp:emulate-color-scheme page (first (run-context-schemes ctx))
                                     :timeout *step-timeout*))))
      (when found
        (%fail "axe-core ~A found ~D violation~:P at ~(~A~) or above: ~{~A~^; ~}"
               version (length found) impact (reverse found))))))
