;;;; temporary-tests.lisp --- MAKE-TEMPORARY-DIRECTORY gives no directory twice, within a process
;;;; or across processes (#515).

(in-package #:aion/fs/tests)

;;; FiveAM's current suite does not carry over from the file before.
(in-suite all)

(defun %subdirectories (dir)
  (mapcar #'namestring (uiop:subdirectories dir)))

(test a-temporary-directory-is-new-empty-and-named-for-this-process
  (let* ((parent (%fresh))
         (a (aion/fs:make-temporary-directory "t515" :in parent))
         (b (aion/fs:make-temporary-directory "t515" :in parent)))
    (unwind-protect
         (progn
           (is (not (equal a b)))
           (is (uiop:directory-exists-p a))
           (is (null (uiop:directory-files a)) "empty")
           (is (search (format nil "t515-~D-" (aion/fs::%process-id)) (namestring a))
               "the name carries this process's id: ~A" a))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore))))

(test a-name-that-already-exists-is-passed-over
  "A directory with the next name already there, as one left by a dead process whose id was
reused, is not handed out: the call takes the next number and leaves the old one alone."
  (let* ((parent (%fresh))
         (taken (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "t515-~D-~D" (aion/fs::%process-id)
                                          (1+ aion/fs::*temporary-count*))
                                  parent))))
    (unwind-protect
         (progn
           (ensure-directories-exist taken)
           (with-open-file (out (merge-pathnames "left.txt" taken) :direction :output)
             (write-string "left by someone else" out))
           (let ((made (aion/fs:make-temporary-directory "t515" :in parent)))
             (is (not (equal (namestring taken) (namestring made))))
             (is (null (uiop:directory-files made)))
             (is (= 1 (length (uiop:directory-files taken))) "the existing directory is untouched")))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore))))

(test threads-of-one-process-get-different-directories
  (let ((parent (%fresh)) (lock (sb-thread:make-mutex)) (made '()))
    (unwind-protect
         (progn
           (aion/test-threads:join-all
                 (loop repeat 8
                       collect (sb-thread:make-thread
                                (lambda ()
                                  (dotimes (i 50)
                                    (let ((d (aion/fs:make-temporary-directory "t515" :in parent)))
                                      (sb-thread:with-mutex (lock) (push (namestring d) made))))))))
           (is (= 400 (length made)))
           (is (= 400 (length (remove-duplicates made :test #'string=))))
           (is (= 400 (length (%subdirectories parent)))))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore))))

(defun %wait-for (predicate seconds)
  "Poll PREDICATE every 0.05 s for at most SECONDS. Returns its true value, or NIL."
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        for value = (funcall predicate)
        when value return value
        while (< (get-internal-real-time) deadline)
        do (sleep 0.05)))

(test two-processes-started-together-get-different-directories
  "The case #515 is about: two fresh SBCL images, which share a random state, each make 50
directories under one prefix in one parent at the same moment. Each child loads aion/fs, says it
is ready, and waits for a go file, so the two make their directories together rather than one
after the other (Copilot's review of #516). All 100 are distinct and exist."
  (let* ((parent (%fresh))
         (control (%fresh))
         (go (merge-pathnames "go" control))
         ;; One form per step, each read after the one before has run: AION/FS does not exist
         ;; when the first is read.
         (forms (lambda (k)
                  (list "(require :asdf)" "(asdf:load-system \"aion/fs\")"
                        (format nil "(with-open-file (s ~S :direction :output :if-exists :supersede) (write-string \"ready\" s))"
                                (uiop:native-namestring (merge-pathnames (format nil "ready-~D" k) control)))
                        (format nil "(loop repeat 1200 until (probe-file ~S) do (sleep 0.05))"
                                (uiop:native-namestring go))
                        (format nil "(dotimes (i 50) (aion/fs:make-temporary-directory \"t515\" :in ~S))"
                                (uiop:native-namestring parent)))))
         (processes (loop for k from 1 to 2
                          collect (uiop:launch-program
                                   (append (list (namestring sb-ext:*runtime-pathname*)
                                                 "--core" (namestring sb-ext:*core-pathname*)
                                                 "--noinform" "--non-interactive" "--no-userinit")
                                           (loop for f in (funcall forms k) append (list "--eval" f)))
                                   :output nil :error-output :output))))
    (unwind-protect
         (progn
           (is-true (%wait-for (lambda () (and (probe-file (merge-pathnames "ready-1" control))
                                               (probe-file (merge-pathnames "ready-2" control))))
                               120)
                    "both children loaded aion/fs and are waiting")
           (with-open-file (s go :direction :output :if-exists :supersede) (write-string "go" s))
           (dolist (p processes)
             (is (eql 0 (%wait-for (lambda () (and (not (uiop:process-alive-p p)) (uiop:wait-process p))) 120))
                 "each child made its directories without an error"))
           (is (= 100 (length (%subdirectories parent)))
               "100 directories, none shared: ~D" (length (%subdirectories parent))))
      (dolist (p processes)
        (when (uiop:process-alive-p p) (ignore-errors (uiop:terminate-process p :urgent t))))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore)
      (aion/fs:delete-tree control :if-does-not-exist :ignore))))

(test a-prefix-must-be-one-plain-name
  "A prefix is parsed as part of a pathname, so one with a separator, a colon, a wildcard, or
dots alone would put the directory somewhere other than IN."
  (let ((parent (%fresh)))
    (unwind-protect
         (progn
           (dolist (bad '("../other" "/tmp/other" "a\\b" "c:x" "a*" "a?" "" "." ".."))
             (signals error (aion/fs:make-temporary-directory bad :in parent)))
           (is (null (uiop:subdirectories parent)) "nothing was made")
           (finishes (aion/fs:make-temporary-directory "plain-name.1" :in parent)))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore))))
