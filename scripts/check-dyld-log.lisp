;;;; check-dyld-log.lisp --- read a DYLD_PRINT_LIBRARIES log by each library's last state (#783).
;;;;
;;;;     sbcl --script scripts/check-dyld-log.lisp loaded LOG
;;;;     sbcl --script scripts/check-dyld-log.lisp openssl LOG BUNDLE-DIRECTORY
;;;;     sbcl --script scripts/check-dyld-log.lisp carried LOG BUNDLE-DIRECTORY FILE-NAME
;;;;
;;;; `loaded' prints one line per library still loaded at the end of the run: the PID, the
;;;; process's executable name and the library's path, separated by tabs. Exit 0.
;;;;
;;;; `openssl' prints one line per loaded libssl or libcrypto, saying whether it is the bundle's
;;;; own copy, Apple's copy loaded by WebKit in hyperion-view, or neither. Exit 1 when one is
;;;; neither, 0 otherwise, including when none was loaded.
;;;;
;;;; `carried' prints one line per loaded library named FILE-NAME, a library the bundle carries,
;;;; saying whether it is the bundle's copy, Apple's copy in hyperion-view, or a copy from outside
;;;; the bundle (#899). Exit 1 when one is from outside, even beside the bundle's copy; 0 when the
;;;; bundle's copy was loaded and none from outside; 3 when no copy was loaded.
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
  (sb-ext:exit :code 2))

(defun %print-findings (findings)
  (loop for (verdict process pid path) in findings
        do (format t "  ~A -- ~A (pid ~D) loaded ~A~A~%"
                   (if (eq verdict :fail) "FAIL" "ok") process pid path
                   (ecase verdict
                     (:carried ", the bundle's own copy")
                     (:webkit ", Apple's copy, which WebKit loads")
                     (:fail ", which is not the bundle's copy")))))

(destructuring-bind (&optional mode log bundle name &rest more) (rest sb-ext:*posix-argv*)
  (unless (and log (probe-file log) (null more)
               (or (and (equal mode "loaded") (null bundle) (null name))
                   (and (equal mode "openssl") bundle (null name))
                   (and (equal mode "carried") bundle name)))
    (%usage))
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
                                 (:fail ", which the bundle does not carry")))))
          (sb-ext:exit :code (if (find :fail findings :key #'first) 1 0))))))
