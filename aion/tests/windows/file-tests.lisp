;;;; file-tests.lisp --- CreateFileW with share mode 0 gives a handle no other open can share.
;;;;
;;;; hades/single-instance depends on exactly this: while one handle to the file is open with
;;;; share mode 0, a second CreateFileW on it fails with ERROR_SHARING_VIOLATION, and once the
;;;; handle is closed the file opens again. Tested in one process, because a sharing violation
;;;; is decided per handle, not per process.

(in-package #:aion/windows/tests)

(def-suite files :description "CreateFileW." :in all)
(in-suite files)

(defun %exclusive-open (path)
  "CreateFileW PATH for reading and writing with share mode 0. Returns (values HANDLE
LAST-ERROR); HANDLE is not valid when the open failed."
  (w:with-wide-string (p (uiop:native-namestring path))
    (let* ((raw (ffi:create-file-w p (logior ffi:+generic-read+ ffi:+generic-write+) 0
                                   (cffi:null-pointer) ffi:+open-always+
                                   ffi:+file-attribute-normal+ (cffi:null-pointer)))
           (err (w:last-error)))
      (values (w:wrap-handle raw :kind :file) err))))

(test a-second-exclusive-open-is-a-sharing-violation-until-the-first-closes
  (let ((path (merge-pathnames (format nil "aion-windows-file-~36R.lock" (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory))))
    (unwind-protect
         (let ((first (%exclusive-open path)))
           (is (w:handle-valid-p first) "the first exclusive open must succeed")
           (multiple-value-bind (second err) (%exclusive-open path)
             (is (not (w:handle-valid-p second)) "a second exclusive open must fail")
             (is (= ffi:+error-sharing-violation+ err)
                 "it must fail with ERROR_SHARING_VIOLATION (32), got ~A" err))
           (w:close-handle first)
           (let ((third (%exclusive-open path)))
             (is (w:handle-valid-p third) "once the first handle is closed, the file must open again")
             (w:close-handle third)))
      (uiop:delete-file-if-exists path))))
