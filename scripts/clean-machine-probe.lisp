;;;; clean-machine-probe.lisp --- load the tree and report what NATIVE code it pulled in.
;;;;
;;;; Driven by scripts/verify-clean-machine.ps1; not useful on its own.
;;;;
;;;;   sbcl --script scripts/clean-machine-probe.lisp --out <file>
;;;;
;;;; ONE IMAGE, DELIBERATELY, and it is the one place this repo does that on purpose.
;;;; `scripts/verify-tree.lisp' loads each system in its OWN image so that a missing
;;;; `:depends-on' cannot be satisfied by a sibling -- that question is about how the tree
;;;; is composed. This one is about the LOADER ENVIRONMENT: which native libraries the tree
;;;; needs, all of them, in one place, so the caller can ask where each came from. Splitting
;;;; that across 25 images would answer a question nobody asked and lose the list.
;;;;
;;;; A LOAD FAILURE IS REPORTED, NOT SIGNALLED. On a machine missing a native library the
;;;; first failure is the interesting one and so is the fifth: reporting only the first
;;;; sends a reader round the loop once per missing library, which is the serial-discovery
;;;; complaint `setup.sh' already carries.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defun argv-value (name &optional default)
  (let ((tail (member name (rest sb-ext:*posix-argv*) :test #'string=)))
    (or (second tail) default)))

(defparameter *out* (or (argv-value "--out")
                        (error "clean-machine-probe: --out is required")))

;;; --- WHICH SYSTEMS TO LOAD: DERIVED, NOT RESTATED (pre-publication issue 283) ---------------------------
;;;
;;; This list used to be hand-written here, and it had already drifted: 28 systems against
;;; the gate's 39, with `aion/secret' and `aion/secret/types' missing because they landed
;;; in b90dc94 AFTER it was written. The consequence was measurable and pointed at exactly
;;; the wrong place -- 9 native libraries seen where 12 were loadable, and the three it
;;; could not see (ole32, oleaut32, user32) arrive through `aion/windows/com', THE TREE'S
;;; ONLY WINDOWS-SPECIFIC NATIVE BINDING. A Windows clean-machine harness blind to the one
;;; Windows-specific thing in the tree is a checker most specialised where it cannot see.
;;;
;;; Two sources, because the tree has two and they answer different questions:
;;;
;;;   scripts/verify-tree.lisp's +SYSTEMS+   the portable systems the gate loads
;;;   scripts/platform-packages.lisp         which platform packages THIS host owns
;;;
;;; platform-packages.lisp is designed to be loaded by path -- bootstrap.lisp and
;;; verify-tree.lisp already both do, for the same anti-drift reason. verify-tree.lisp is
;;; not: loading it RUNS the gate. So its list is read form by form and only that one
;;; definition evaluated -- the same technique scripts/vswhere-probe.lisp uses on
;;; build-libuv.lisp, and for the same reason: a second copy of the answer is the
;;; producer/consumer defect this tree keeps finding, in a script whose whole purpose is to
;;; report faithfully.
;;;
;;; IF +SYSTEMS+ IS RENAMED THIS EXITS 2 RATHER THAN PROBING A SHORTER TREE. A derivation
;;; that silently falls back to nothing is the drift it replaces, wearing a better costume.

(defparameter *scripts-dir*
  (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))

(load (merge-pathnames "platform-packages.lisp" *scripts-dir*))

(defun %gate-systems ()
  "+SYSTEMS+ from verify-tree.lisp, read rather than re-declared."
  (let ((file (merge-pathnames "verify-tree.lisp" *scripts-dir*))
        (found :none))
    (with-open-file (in file :external-format :utf-8)
      (let ((*package* (find-package :cl-user)))
        (loop for form = (handler-case (read in nil :eof) (error () :eof))
              until (eq form :eof)
              do (when (and (consp form)
                            (eq (first form) 'defparameter)
                            (string= (symbol-name (second form)) "+SYSTEMS+"))
                   (setf found (eval (third form)))))))
    (when (eq found :none)
      (format *error-output*
              "~&clean-machine-probe: +SYSTEMS+ not found in ~A -- it has been renamed.~%~
               Refusing to probe a list I cannot derive: a short list here reports a~%~
               CLEANER machine than the tree actually needs, which is the failure this~%~
               file exists to catch.~%" file)
      (finish-output *error-output*)
      (sb-ext:quit :unix-status 2))
    found))

(defun %platform-systems ()
  "The platform packages THIS host owns and is expected to have -- aion/windows and
aion/windows/com on Windows. These are the whole point: they are the only systems in the
tree whose native dependencies are platform-specific by construction."
  (loop for entry in (funcall (read-from-string "ouranos-platform:entries-here"))
        when (funcall (read-from-string "ouranos-platform:required-p") entry)
          collect (intern (string-upcase
                           (funcall (read-from-string "ouranos-platform:entry-system") entry))
                          :keyword)))

(defparameter *systems* (append (%gate-systems) (%platform-systems))
  "Every system this host should be able to load with nothing but what we provision.

`aion/uv' and `hyperion/server-uv' are absent because +SYSTEMS+ does not carry them --
they need a vendored libuv that a fresh checkout has not built (pre-publication issue 128), and verify-tree
folds them in only under OURANOS_WITH_UV. Inheriting that decision rather than restating
it is the point of deriving.")

(defun probe-systems ()
  (let ((failures '()))
    (dolist (s *systems* (nreverse failures))
      (handler-case
          (progn (funcall (read-from-string "ql:quickload") s :silent t)
                 (format t "~&  ok      ~A~%" s))
        (error (e)
          (let ((text (substitute #\Space #\Newline (princ-to-string e))))
            (push (cons s (subseq text 0 (min 300 (length text)))) failures)
            (format t "~&  FAILED  ~A~%             ~A~%" s (car (last failures)))))))))

(defun loaded-native-libraries ()
  "Every shared object this image has open, by name.

SBCL's own list rather than CFFI's, because it includes libraries pulled in TRANSITIVELY by
another library rather than by a `define-foreign-library' this tree can see. The question
being asked is what the machine had to supply, and that is not limited to what we asked for
by name."
  (sort (remove-duplicates
         (remove nil
                 (mapcar (lambda (o)
                           (ignore-errors
                            (let ((n (sb-alien::shared-object-namestring o)))
                              (and (stringp n) (file-namestring n)))))
                         sb-sys:*shared-objects*))
         :test #'string-equal)
        #'string-lessp))

(let ((failures (probe-systems))
      (libs (loaded-native-libraries)))
  (with-open-file (out *out* :direction :output :if-exists :supersede
                             :external-format :utf-8)
    ;; A flat, greppable format on purpose: the caller is PowerShell, and a reader looking
    ;; at a failed CI run should be able to understand the file without a parser.
    (dolist (l libs) (format out "LIB ~A~%" l))
    (dolist (f failures) (format out "FAILED-SYSTEM ~A :: ~A~%" (car f) (cdr f))))
  (format t "~&~%wrote ~A: ~D native ~:*~[libraries~;library~:;libraries~], ~D failed system~:P~%"
          *out* (length libs) (length failures))
  (finish-output)
  (sb-ext:quit :unix-status (if failures 1 0)))
