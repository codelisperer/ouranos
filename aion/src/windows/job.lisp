;;;; job.lisp --- job objects that end their processes when the job is closed (#599).
;;;;
;;;; On Windows, ending a process does not end the processes it started. A job object does: with
;;;; JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, Windows ends every process in the job when the last
;;;; handle to the job is closed, and a process started by one in the job is in the job too. The
;;;; handle is closed by CLOSE-HANDLE, or by Windows when the image holding it exits, however it
;;;; exits.
;;;;
;;;; A process can be in several jobs on Windows 8 and later, so assigning a process works when
;;;; this image itself runs in a job, unless that job's limits forbid it. A process starts
;;;; running before it can be assigned, so a process it starts in that window is not in the job.

(in-package #:aion/windows)

(defun %non-null-p (pointer) (not (cffi:null-pointer-p pointer)))
(defun %true-p (result) (not (zerop result)))

(defun make-kill-on-close-job ()
  "Create an unnamed job object that ends every process in it when its last handle is closed,
and return its HANDLE. Signals WIN32-ERROR when Windows refuses either step; no handle is left
open then."
  (let ((job (wrap-handle (check-win32 (ffi:create-job-object-w (cffi:null-pointer)
                                                                (cffi:null-pointer))
                                       :operation :create-job-object :predicate #'%non-null-p)
                          :kind :job))
        (done nil))
    (unwind-protect
         (cffi:with-foreign-object (info '(:struct ffi:jobobject-extended-limit-information))
           (let ((size (cffi:foreign-type-size '(:struct ffi:jobobject-extended-limit-information))))
             (dotimes (i size)
               (setf (cffi:mem-aref info :uint8 i) 0))
             (setf (cffi:foreign-slot-value
                    (cffi:foreign-slot-pointer info '(:struct ffi:jobobject-extended-limit-information)
                                               'ffi:basic-limit-information)
                    '(:struct ffi:jobobject-basic-limit-information) 'ffi:limit-flags)
                   ffi:+job-object-limit-kill-on-job-close+)
             (check-win32 (ffi:set-information-job-object
                           (handle-pointer job) ffi:+job-object-extended-limit-information+
                           info size)
                          :operation :set-information-job-object :predicate #'%true-p)
             (setf done t)))
      (unless done (close-handle job)))
    job))

(defun assign-process-to-job (job pid)
  "Put the process PID in JOB. Signals WIN32-ERROR when the process cannot be opened, for
instance because it has exited or PID is 0, or cannot be assigned. Returns T."
  (with-handle (process (wrap-handle (check-win32 (ffi:open-process
                                                   (logior ffi:+process-set-quota+
                                                           ffi:+process-terminate+)
                                                   0 pid)
                                                  :operation :open-process
                                                  :predicate #'%non-null-p)
                                     :kind :process))
    (check-win32 (ffi:assign-process-to-job-object (handle-pointer job) (handle-pointer process))
                 :operation :assign-process-to-job-object :predicate #'%true-p)
    t))

(defun terminate-job (job &optional (exit-code 1))
  "End every process in JOB, each with EXIT-CODE. The job stays open, and CLOSE-HANDLE still
has to close it. Signals WIN32-ERROR when Windows refuses. Returns T."
  (check-win32 (ffi:terminate-job-object (handle-pointer job) exit-code)
               :operation :terminate-job-object :predicate #'%true-p)
  t)
