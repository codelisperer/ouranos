;;;; lazy-natives.lisp --- every library the bundler wakes and carries resolves against the
;;;; module that loads it (#481)
;;;;
;;;; scripts/lazy-natives.lisp names each library's package, loader, unloader and variables as
;;;; strings. A string that no longer matches the module resolves to nothing, and the bundler
;;;; reads that as "this app does not use the library": it carries nothing and says so in one
;;;; line of a long build log. So for each entry, a child image loads the entry's system and
;;;; checks that every name resolves, that the loader opens a library under vendor/ by a name
;;;; the module's own search asks for, and that the unloader closes it again, which is what
;;;; the bundler needs before the dump (ADR-0013).
;;;;
;;;; THE CONTROL is the same check on an entry whose loader is misspelt. It must report the
;;;; name, and it needs no built library, so it runs on every host.
;;;;
;;;; A library this host has not built is skipped, and the skip names its build script.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "lazy-natives.lisp" *scripts*)))

(defun %lazy-native-report (entry)
  "Run the check for ENTRY in a child image. Returns its output lines, each \"KEY value\"."
  (destructuring-bind (package loader unloader path-var names-var build-script system) entry
    (declare (ignore build-script))
    (let* ((out (make-string-output-stream))
           (form
             (format nil "(let* ((p (find-package ~S)) (sym (lambda (n) (and p (find-symbol n p)))) (loader (funcall sym ~S)) (unloader (funcall sym ~S)) (path-var (funcall sym ~S)) (names-var (funcall sym ~S))) (format t \"~~&PACKAGE ~~A~~%LOADER ~~A~~%UNLOADER ~~A~~%PATH-VARIABLE ~~A~~%NAMES-VARIABLE ~~A~~%\" (and p t) (and loader (fboundp loader) t) (and unloader (fboundp unloader) t) (and path-var (boundp path-var) t) (and names-var (boundp names-var) t)) (when (and loader (fboundp loader) unloader (fboundp unloader) path-var (boundp path-var) names-var (boundp names-var)) (handler-case (progn (funcall loader) (let ((path (symbol-value path-var))) (format t \"~~&PATH ~~A~~%NAMES ~~{~~A~~^ ~~}~~%\" path (symbol-value names-var)) (funcall unloader) (format t \"~~&OPEN-AFTER-UNLOAD ~~A~~%\" (and (find-if (lambda (l) (let ((f (ignore-errors (truename (cffi:foreign-library-pathname l))))) (and f (equal f (ignore-errors (truename path)))))) (cffi:list-foreign-libraries :loaded-only t)) t)))) (error (e) (format t \"~~&LOAD-ERROR ~~A~~%\" (type-of e))))) (finish-output))"
                     package loader unloader path-var names-var)))
      (uiop:run-program
       (list (uiop:native-namestring sb-ext:*runtime-pathname*)
             "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
             "--eval" "(require :asdf)"
             "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
             "--eval" (format nil "(asdf:load-system ~S)" system)
             "--eval" form)
       :output out :error-output out :ignore-error-status t)
      (uiop:split-string (get-output-stream-string out) :separator '(#\Newline)))))

(defun %report-value (lines key)
  (let ((line (find-if (lambda (l) (uiop:string-prefix-p (concatenate 'string key " ") l)) lines)))
    (and line (subseq line (1+ (length key))))))

(defun %lazy-native-problems (entry lines)
  "What is wrong with ENTRY according to its child's report LINES, as a list of strings."
  (let ((problems '()))
    (dolist (key '("PACKAGE" "LOADER" "UNLOADER" "PATH-VARIABLE" "NAMES-VARIABLE"))
      (unless (equal "T" (%report-value lines key))
        (push (format nil "~A ~A does not resolve in ~A" key
                      (nth (position key '("PACKAGE" "LOADER" "UNLOADER" "PATH-VARIABLE" "NAMES-VARIABLE")
                                     :test #'string=)
                           entry)
                      (first entry))
              problems)))
    (let ((path (%report-value lines "PATH"))
          (names (%report-value lines "NAMES")))
      (when path
        (unless (uiop:subpathp (ignore-errors (truename path))
                               (truename (merge-pathnames "vendor/" td-root)))
          (push (format nil "the loader opened ~A, outside vendor/" path) problems))
        (unless (member (file-namestring path) (uiop:split-string (or names "") :separator " ")
                        :test #'string=)
          (push (format nil "~A is not among the names the module searches for (~A)"
                        (file-namestring path) names)
                problems))
        (unless (equal "NIL" (%report-value lines "OPEN-AFTER-UNLOAD"))
          (push "the unloader left the library open" problems))))
    (nreverse problems)))

(test every-lazy-native-resolves-loads-from-vendor-and-unloads
  "Each entry of scripts/lazy-natives.lisp, checked in a child image that loads its system."
  (dolist (entry ouranos-lazy-natives:*lazy-natives*)
    (let* ((lines (%lazy-native-report entry))
           (load-error (%report-value lines "LOAD-ERROR")))
      (if (and load-error (search "NOT-FOUND" load-error))
          (skip "~A: the library is not built here; run scripts/~A"
                (first entry) (ouranos-lazy-natives:entry-build-script entry))
          (progn
            (is (null load-error) "~A: the loader signalled ~A" (first entry) load-error)
            (is (%report-value lines "PATH") "~A: the loader recorded no path~%~{~A~%~}"
                (first entry) lines)
            (let ((problems (%lazy-native-problems entry lines)))
              (is (null problems) "~A: ~{~A~^; ~}" (first entry) problems)))))))

(test a-misspelt-lazy-native-name-is-reported
  "CONTROL: aion/uv's entry with its loader misspelt. The check must name the loader."
  (let* ((entry (copy-list (find "AION/UV/FFI" ouranos-lazy-natives:*lazy-natives*
                                 :key #'first :test #'string=)))
         (broken (list* (first entry) "LOAD-LIBUVV" (cddr entry)))
         (problems (%lazy-native-problems broken (%lazy-native-report broken))))
    (is (find-if (lambda (p) (search "LOADER LOAD-LIBUVV does not resolve" p)) problems)
        "problems reported: ~S" problems)))
