;;;; single-instance-tests.lisp --- the lock is exclusive, per directory, and dies with its process.
;;;;
;;;; #305's acceptance, as tests: a second process on the same directory gets :BUSY, and
;;;; killing the first process frees the lock at once. The cross-process tests start a child
;;;; SBCL that takes the lock, prints HELD and waits. Each directory is fresh, so no test can
;;;; pass because of a file an earlier run left.

(defpackage #:hades/single-instance/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:si #:hades/single-instance))
  (:export #:run-tests))

(in-package #:hades/single-instance/tests)

(def-suite all :description "hades/single-instance.")
(in-suite all)

(defun run-tests ()
  (fiveam:run! 'all))

(defun %fresh-directory ()
  (ensure-directories-exist
   (merge-pathnames (format nil "hades-si-~36R/" (random (expt 36 10) (make-random-state t)))
                    (uiop:temporary-directory))))

;;; --- in one process ------------------------------------------------------------------

(test a-second-acquire-in-the-same-process-is-busy-until-released
  ;; fcntl locks belong to the process, so without the table this passes on Windows and
  ;; fails on Linux and macOS: the second acquire would succeed.
  (let* ((dir (%fresh-directory))
         (first (si:acquire-single-instance "app" :directory dir)))
    (is (si:single-instance-lock-p first))
    (is (eq :busy (si:acquire-single-instance "app" :directory dir)))
    (si:release-single-instance first)
    (si:release-single-instance first)            ; a second release does nothing
    (let ((again (si:acquire-single-instance "app" :directory dir)))
      (is (si:single-instance-lock-p again) "released, it must be free again")
      (si:release-single-instance again))))

(test another-directory-or-name-is-another-lock
  (let* ((a (si:acquire-single-instance "app" :directory (%fresh-directory)))
         (b (si:acquire-single-instance "app" :directory (%fresh-directory)))
         (dir (si:single-instance-lock-path a))
         (c (si:acquire-single-instance "other" :directory (uiop:pathname-directory-pathname dir))))
    (is (si:single-instance-lock-p a))
    (is (si:single-instance-lock-p b) "a second data directory is a second lock")
    (is (si:single-instance-lock-p c) "a second name is a second lock")
    (mapc #'si:release-single-instance (list a b c))))

(test a-left-over-lock-file-locks-nothing
  ;; The charter's rule, "never a lock file": the file existing must not mean locked, or a
  ;; crash would lock the app out of its next start.
  (let* ((dir (%fresh-directory))
         (path (si:lock-path "app" :directory dir)))
    (with-open-file (s path :direction :output :if-exists :supersede) (write-line "stale" s))
    (let ((lock (si:acquire-single-instance "app" :directory dir)))
      (is (si:single-instance-lock-p lock) "a file nobody holds must not block the lock")
      (when (si:single-instance-lock-p lock) (si:release-single-instance lock)))))

(test with-single-instance-runs-the-body-or-on-busy
  (let ((dir (%fresh-directory)))
    (is (eq :ran (si:with-single-instance ("app" :directory dir) :ran)))
    (is (eq :other-copy
            (si:with-single-instance ("app" :directory dir)
              (si:with-single-instance ("app" :directory dir :on-busy (lambda () :other-copy))
                :ran-twice))))
    (signals si:single-instance-busy
      (si:with-single-instance ("app" :directory dir)
        (si:with-single-instance ("app" :directory dir) :ran-twice)))
    (is (eq :ran (si:with-single-instance ("app" :directory dir) :ran))
        "the lock must be released when the body exits, even by a signal")))

(test a-name-that-is-not-a-file-name-is-refused
  (signals error (si:lock-path "../app" :directory (%fresh-directory)))
  (signals error (si:lock-path "" :directory (%fresh-directory))))

;;; --- across processes ----------------------------------------------------------------

(defun %holder (dir)
  "Start a child SBCL that takes the lock for \"app\" in DIR, prints HELD, and waits. Returns
the process once it has printed HELD."
  (let* ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
         (process (uiop:launch-program
                   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                         "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                         "--eval" "(require :asdf)"
                         "--eval" (format nil "(load ~S)" (uiop:native-namestring setup))
                         ;; This tree, named explicitly, so the child loads the code under test
                         ;; and not whatever tree its inherited configuration points at.
                         "--eval" (format nil "(asdf:initialize-source-registry '(:source-registry (:tree ~S) :inherit-configuration))"
                                          (uiop:native-namestring
                                           (uiop:pathname-parent-directory-pathname
                                            (asdf:system-source-directory "hades/single-instance"))))
                         "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system \"hades/single-instance\"))"
                         "--eval" (format nil "(let ((l (hades/single-instance:acquire-single-instance \"app\" :directory ~S))) (format t \"~~&~~A~~%\" (if (eq l :busy) \"BUSY\" \"HELD\")) (finish-output) (sleep 600))"
                                          (uiop:native-namestring dir)))
                   :output :stream :error-output nil)))
    (let ((line (read-line (uiop:process-info-output process) nil "")))
      (unless (string= "HELD" (string-trim '(#\Return #\Space) line))
        (uiop:terminate-process process :urgent t)
        (error "the child did not take the lock: ~S" line)))
    process))

(test a-second-process-is-busy-and-killing-the-first-frees-the-lock-at-once
  (let* ((dir (%fresh-directory))
         (child (%holder dir)))
    (unwind-protect
         (progn
           (is (eq :busy (si:acquire-single-instance "app" :directory dir))
               "another process holds it, so this one must be busy")
           (uiop:terminate-process child :urgent t)
           (uiop:wait-process child)
           ;; No retry: the operating system releases the lock as the process ends.
           (let ((lock (si:acquire-single-instance "app" :directory dir)))
             (is (si:single-instance-lock-p lock)
                 "once the holder is killed, the lock must be free at once")
             (when (si:single-instance-lock-p lock) (si:release-single-instance lock))))
      (when (uiop:process-alive-p child)
        (uiop:terminate-process child :urgent t)))))
