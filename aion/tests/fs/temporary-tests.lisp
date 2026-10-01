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
           (mapc #'sb-thread:join-thread
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

(test two-processes-started-together-get-different-directories
  "The case #515 is about: two fresh SBCL images, which share a random state, each make 50
directories under one prefix in one parent at the same moment. All 100 are distinct and exist."
  (let* ((parent (%fresh))
         ;; Three forms, each read after the one before has run: AION/FS does not exist yet
         ;; when the first is read.
         (forms (list "(require :asdf)" "(asdf:load-system \"aion/fs\")"
                      (format nil "(dotimes (i 50) (aion/fs:make-temporary-directory \"t515\" :in ~S))"
                              (uiop:native-namestring parent))))
         (processes (loop repeat 2
                          collect (uiop:launch-program
                                   (append (list (namestring sb-ext:*runtime-pathname*)
                                                 "--core" (namestring sb-ext:*core-pathname*)
                                                 "--noinform" "--non-interactive" "--no-userinit")
                                           (loop for f in forms append (list "--eval" f)))
                                   :output nil :error-output :output))))
    (unwind-protect
         (progn
           (dolist (p processes)
             (is (zerop (uiop:wait-process p)) "each child made its directories without an error"))
           (is (= 100 (length (%subdirectories parent)))
               "100 directories, none shared: ~D" (length (%subdirectories parent))))
      (aion/fs:delete-tree parent :if-does-not-exist :ignore))))
