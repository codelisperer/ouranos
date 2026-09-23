;;;; with-mode.lisp --- run a script under a chosen COALTON COMPILATION MODE (#98).
;;;;
;;;;   sbcl --script scripts/with-mode.lisp release scripts/verify-tree.lisp
;;;;   sbcl --script scripts/with-mode.lisp dev     scripts/bench.lisp
;;;;   sbcl --script scripts/with-mode.lisp release scripts/bench.lisp --iterations 200
;;;;
;;;; Exits with the child's exit code.
;;;;
;;;; WHY THIS EXISTS. Coalton compiles in one of two GLOBAL modes, fixed before Coalton
;;;; itself is built:
;;;;
;;;;   development (default)  types are mostly CLOS objects, redefinable; several
;;;;                          optimizations disabled for debuggability
;;;;   release                types are frozen defstructs, flattened/unwrapped;
;;;;                          optimizations applied
;;;;
;;;; The mode is a property of the BUILD, not of a system -- Coalton's own stdlib included
;;;; -- so it cannot be switched inside a running image, and "just try release mode" is a
;;;; full rebuild. That is the entire reason this is a script rather than an instruction in
;;;; a doc for someone to run by hand (aion/docs/cl-shell-design.md §3).
;;;;
;;;; THE PART THAT WOULD OTHERWISE BITE SILENTLY. `:coalton-release` is a FEATURE, and
;;;; ASDF's default output translations do NOT encode features in the fasl path. So a
;;;; release-mode run against the ordinary cache happily LOADS development-mode fasls, and
;;;; reports a release number for a development build. Every mode gets its own cache here,
;;;; which is why this does not tell you to clear anything: clearing makes the two modes
;;;; alternate expensively and still shares one namespace. Two caches make them
;;;; independent and repeatable.
;;;;
;;;; BOTH modes are isolated, not just release. If development used the default cache it
;;;; would inherit fasls from whatever REPL the developer last ran, which is not a
;;;; controlled comparison -- and a benchmark whose baseline came from somewhere else is
;;;; the thing #98 exists to stop.

(require :asdf)
(require :uiop)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defun usage (&optional (stream *error-output*))
  (format stream "~&usage: sbcl --script scripts/with-mode.lisp <dev|release> <script> [args...]~%")
  (format stream "       modes: dev (development, the default Coalton build) | release~%"))

(defun mode-cache (mode)
  "The fasl cache for MODE. Under the user's cache directory, never in the tree: it is
build output, it is large, and two of them exist."
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil ".cache/ouranos/fasl-~(~a~)/" mode)
                    (user-homedir-pathname))))

(let* ((args (uiop:command-line-arguments))
       (mode (first args))
       (script (second args))
       (rest (cddr args)))

  (unless (and mode script)
    (usage) (uiop:quit 2))

  (let ((mode (cond ((member mode '("dev" "development") :test #'string-equal) :development)
                    ((string-equal mode "release") :release)
                    (t (format *error-output* "~&with-mode: unknown mode ~s~%" mode)
                       (usage)
                       (uiop:quit 2)))))

    (let* ((cache (mode-cache mode))
           (script-path (merge-pathnames script *root*)))
      (ensure-directories-exist cache)
      (unless (probe-file script-path)
        (format *error-output* "~&with-mode: no such script: ~a~%" script-path)
        (uiop:quit 2))

      ;; The entry separator is `:` on Unix and `;` on Windows -- a colon there would be
      ;; read as part of the `d:` drive letter. Ask UIOP rather than assuming; hardcoding
      ;; it is what once made all 36 of verify-tree's children resolve nothing on Windows.
      (let* ((translations (format nil "/~A~A" (uiop:inter-directory-separator)
                                   (uiop:native-namestring cache)))
             (env (list* (format nil "COALTON_ENV=~A"
                                 (if (eq mode :release) "release" "development"))
                         (format nil "ASDF_OUTPUT_TRANSLATIONS=~A" translations)
                         (remove-if (lambda (e)
                                      (or (uiop:string-prefix-p "COALTON_ENV=" e)
                                          (uiop:string-prefix-p "ASDF_OUTPUT_TRANSLATIONS=" e)))
                                    (sb-ext:posix-environ)))))

        (format t "~&========== ~(~a~) mode ==========~%" mode)
        (format t "cache:  ~a~%" (uiop:native-namestring cache))
        (format t "script: ~a~{ ~a~}~%~%" script rest)
        (finish-output)

        (let ((code (nth-value
                     2 (uiop:run-program
                        (append (list (namestring sb-ext:*runtime-pathname*)
                                      "--dynamic-space-size" "4096"
                                      "--script" (namestring script-path))
                                rest)
                        :output t :error-output t
                        :environment env
                        :ignore-error-status t))))
          (uiop:quit code))))))
