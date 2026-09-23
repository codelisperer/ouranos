;;;; tempdir.lisp --- scratch directories that are created, not chosen (#204).
;;;;
;;;; The idiom this replaces appeared in cons/src/template.lisp and four times in
;;;; cons/tests: build a name from (random 100000000), hand it to ENSURE-DIRECTORIES-EXIST,
;;;; write a project into it. That is two separate defects, and only the smaller one is
;;;; about randomness.

(in-package #:cons/tempdir)

(defparameter *attempts* 32
  "How many names to try before giving up. A collision is expected to be rare and a
persistent one means something is wrong with the temporary directory itself -- so the loop
is bounded, and exhausting it is an error rather than a hang.")

(define-condition temporary-directory-error (error)
  ((directory :initarg :directory :reader temporary-directory-error-directory)
   (attempts :initarg :attempts :reader temporary-directory-error-attempts))
  (:report
   (lambda (c stream)
     (format stream "cons: could not create a private temporary directory under ~A after ~D attempts.~%"
             (namestring (temporary-directory-error-directory c))
             (temporary-directory-error-attempts c))
     (format stream "~%Something is wrong with that directory rather than with the name:~%")
     (format stream "  - it may be full, read-only, or missing~%")
     (format stream "  - TMPDIR may point somewhere that does not exist~%")))
  (:documentation "Signalled when no scratch directory could be created."))

;;; --- naming ----------------------------------------------------------------

(defvar *name-state* (make-random-state t)
  "A random state SEEDED PER IMAGE.

CL:*RANDOM-STATE* is not: SBCL starts every image with the same one, so `(random n)' against
the default produced the SAME suffix sequence on every run of `cons'. Two concurrent `cons'
processes therefore collided on their first temp directory far more often than the range
suggests.

This is COLLISION AVOIDANCE and nothing more. It is deliberately not a CSPRNG, and reading
it as the security fix would be reading this file backwards -- the security property comes
from %CREATE-EXCLUSIVELY being atomic. A better random source cannot make choose-then-write
safe, and would only make it look safe.")

(defun %candidate (tag)
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "cons-~A-~D-~36R"
                            tag (sb-unix:unix-getpid) (random (expt 36 8) *name-state*))
                    (uiop:temporary-directory))))

;;; --- creation --------------------------------------------------------------

(defun %create-exclusively (dir)
  "Create DIR atomically. T if we created it, NIL if something was already there.

MKDIR IS THE O_EXCL OF DIRECTORIES, and that is the whole fix. It is atomic, and it fails
with EEXIST if anything already occupies the path -- INCLUDING A SYMLINK, which is the case
that matters. So the caller cannot be raced into adopting someone else's directory.

What the old code did instead: ENSURE-DIRECTORIES-EXIST succeeds when the directory already
exists, and on Unix it FOLLOWS a symlink. In a world-writable /tmp, anyone able to guess the
name could pre-create it pointing elsewhere, and cons would then generate a project through
the link with its own privileges. Making the name unguessable would not have fixed that; not
choosing a name and hoping is what fixes it.

Mode #o700 is the second half. Even a correctly created directory in a shared /tmp should
not be readable by other users while a project is generated inside it.

Any error that is NOT `already there' is re-signalled: a full disk is not a name collision,
and retrying 32 times would turn one clear failure into a slow, confusing one."
  #+unix
  (handler-case (progn (sb-posix:mkdir (uiop:native-namestring dir) #o700) t)
    (sb-posix:syscall-error (e)
      (if (= (sb-posix:syscall-errno e) sb-posix:eexist)
          nil
          (error e))))
  ;; Windows: uiop:temporary-directory is %TEMP%, which lives under the user's own profile
  ;; and is not world-writable, so the pre-placed-symlink attack has no analogue. SBCL's
  ;; Windows sb-posix is also thinner than the POSIX one (see cons/tests/packages.lisp), so
  ;; naming sb-posix:mkdir here would be a READ error on that platform rather than a
  ;; run-time one. ENSURE-DIRECTORIES-EXIST reports whether it created anything, which is
  ;; the collision check; it is not the atomicity guarantee, and is not claimed to be.
  #-unix
  (nth-value 1 (ensure-directories-exist dir)))

(defun make-temporary-directory (&optional (tag "tmp"))
  "Create and return a fresh, private scratch directory named after TAG.

The directory EXISTS when this returns, and is ours: nothing else was at that path. The
caller owns removing it -- WITH-TEMPORARY-DIRECTORY is the form that does."
  (loop repeat *attempts*
        for candidate = (%candidate tag)
        when (%create-exclusively candidate)
          return candidate
        finally (error 'temporary-directory-error
                       :directory (uiop:temporary-directory)
                       :attempts *attempts*)))

(defmacro with-temporary-directory ((var &optional (tag "tmp") &key keep) &body body)
  "Bind VAR to a fresh private directory, run BODY, and remove the tree however BODY exits.

KEEP, evaluated after BODY, leaves it in place -- which is what you want the moment
something has failed inside it and you would like to look."
  (let ((dir (gensym "DIR")))
    `(let ((,dir (make-temporary-directory ,tag)))
       (unwind-protect (let ((,var ,dir)) ,@body)
         (unless ,keep
           (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))))
