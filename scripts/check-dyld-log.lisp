;;;; check-dyld-log.lisp --- read a DYLD_PRINT_LIBRARIES log by each library's last state (#783).
;;;;
;;;;     sbcl --script scripts/check-dyld-log.lisp loaded LOG
;;;;     sbcl --script scripts/check-dyld-log.lisp openssl LOG BUNDLE-DIRECTORY
;;;;     sbcl --script scripts/check-dyld-log.lisp carried LOG BUNDLE-DIRECTORY FILE-NAME
;;;;     sbcl --script scripts/check-dyld-log.lisp reported LOG BUNDLE-DIRECTORY
;;;;
;;;; `loaded' prints one line per library still loaded at the end of the run: the PID, the
;;;; process's executable name and the library's path, separated by tabs. Exit 0.
;;;;
;;;; `openssl' prints one line per loaded libssl or libcrypto, saying whether it is the bundle's
;;;; own copy, Apple's copy loaded by WebKit in hyperion-view, Apple's /usr/lib copy in another
;;;; process (#905), or none of those. Exit 1 when one is none of those, 0 otherwise, including
;;;; when none was loaded.
;;;;
;;;; `carried' prints one line per loaded library named FILE-NAME, a library the bundle carries,
;;;; saying whether it is the bundle's copy, Apple's copy in hyperion-view, or a copy from outside
;;;; the bundle (#899). Apple's /usr/lib copy in a process that has Security.framework loaded is
;;;; printed as WAIVED and does not fail (#905). Exit 1 when one is from outside, even beside the
;;;; bundle's copy; 0 when the bundle's copy was loaded and none from outside; 3 when no copy was
;;;; loaded.
;;;;
;;;; `reported' prints one line per `SQLITE-LIBRARY: <version> <path>' line the app wrote to LOG,
;;;; saying whether the library the app reports calling is in the bundle (#905). Exit 1 when one
;;;; is not, 0 otherwise, including when the app reported none.
;;;;
;;;; The rules are in scripts/dyld-libraries.lisp. verify-bundle-macos.sh runs this.

(require :asdf)
(load (merge-pathnames "dyld-libraries.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defun %usage ()
  (write-line "usage: sbcl --script scripts/check-dyld-log.lisp loaded LOG" *error-output*)
  (write-line "       sbcl --script scripts/check-dyld-log.lisp openssl LOG BUNDLE-DIRECTORY"
              *error-output*)
  (write-line "       sbcl --script scripts/check-dyld-log.lisp carried LOG BUNDLE-DIRECTORY FILE-NAME"
              *error-output*)
  (write-line "       sbcl --script scripts/check-dyld-log.lisp reported LOG BUNDLE-DIRECTORY"
              *error-output*)
  (sb-ext:exit :code 2))

(defun %print-findings (findings)
  (loop for (verdict process pid path) in findings
        do (if (eq verdict :security-framework)
               (format t "  WAIVED :security-framework -- ~A (pid ~D) loaded ~A (Security.framework is loaded in this process, #905). This log cannot show which copy the app's calls reach; the app's own report, checked below, has to.~%"
                       process pid path)
               (format t "  ~A -- ~A (pid ~D) loaded ~A~A~%"
                       (if (eq verdict :fail) "FAIL" "ok") process pid path
                       (ecase verdict
                         (:carried ", the bundle's own copy")
                         (:webkit ", Apple's copy, which WebKit loads")
                         (:fail ", which is not the bundle's copy"))))))

(destructuring-bind (&optional mode log bundle name &rest more) (rest sb-ext:*posix-argv*)
  (unless (and log (probe-file log) (null more)
               (or (and (equal mode "loaded") (null bundle) (null name))
                   (and (equal mode "openssl") bundle (null name))
                   (and (equal mode "reported") bundle (null name))
                   (and (equal mode "carried") bundle name)))
    (%usage))
  (when (equal mode "reported")
    (let ((findings (ouranos-dyld-libraries:reported-library-findings
                     (uiop:read-file-string log) bundle)))
      (loop for (verdict version path) in findings
            do (format t "  ~A -- the app reports calling SQLite ~A from ~A~A~%"
                       (if (eq verdict :fail) "FAIL" "ok") version path
                       (if (eq verdict :fail) ", which is not in the bundle" ", the bundle's own copy")))
      (sb-ext:exit :code (if (find :fail findings :key #'first) 1 0))))
  (let ((images (ouranos-dyld-libraries:parse-dyld-log (uiop:read-file-string log))))
    (when (equal mode "carried")
      (let ((findings (ouranos-dyld-libraries:carried-findings images bundle name)))
        (%print-findings findings)
        (sb-ext:exit :code (cond ((find :fail findings :key #'first) 1)
                                 ((find :carried findings :key #'first) 0)
                                 (t 3)))))
    (if (equal mode "loaded")
        (dolist (i (ouranos-dyld-libraries:loaded-images images))
          (format t "~D~C~A~C~A~%" (ouranos-dyld-libraries:image-pid i) #\Tab
                  (ouranos-dyld-libraries:image-process i) #\Tab
                  (ouranos-dyld-libraries:image-path i)))
        (let ((findings (ouranos-dyld-libraries:openssl-findings images bundle)))
          (if (null findings)
              (format t "  ok -- no libssl or libcrypto was loaded on this run~%")
              (loop for (verdict process pid path) in findings
                    do (format t "  ~A -- ~A (pid ~D) loaded ~A~A~%"
                               (if (eq verdict :fail) "FAIL" "ok") process pid path
                               (ecase verdict
                                 (:carried ", the bundle's own copy")
                                 (:webkit ", Apple's copy, which WebKit loads")
                                 (:apple ", Apple's own copy, which every Mac has (#905)")
                                 (:fail ", which the bundle does not carry")))))
          (sb-ext:exit :code (if (find :fail findings :key #'first) 1 0))))))
