;;;; with-mode.lisp --- run a script under a chosen COALTON COMPILATION MODE (pre-publication issue 98).
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
;;;; the thing pre-publication issue 98 exists to stop.

(require :asdf)
(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defun usage (&optional (stream *error-output*))
  (format stream "~&usage: sbcl --script scripts/with-mode.lisp <dev|release> <script> [args...]~%")
  (format stream "       modes: dev (development, the default Coalton build) | release~%"))

(defun mode-cache (mode)
  "The fasl cache for MODE. Under the user's cache directory, never in the tree: it is
build output, it is large, and two of them exist. OURANOS_WITH_MODE_CACHE names another
directory to hold the caches, which the tests use so that they do not write to the user's."
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "fasl-~(~a~)/" mode)
                    (let ((override (uiop:getenv "OURANOS_WITH_MODE_CACHE")))
                      (if (and override (plusp (length override)))
                          (uiop:ensure-directory-pathname (uiop:parse-native-namestring override))
                          (merge-pathnames ".cache/ouranos/" (user-homedir-pathname)))))))

(defun output-translations (cache)
  "ASDF_OUTPUT_TRANSLATIONS for CACHE, in ASDF's s-expression form (#572):

- the source is :ROOT, which matches any path, a Windows path with its drive included. The
  string form \"/;cache\" this replaced named `/' as the source, which has no device, so on
  Windows the first file compiled failed in TRANSLATE-PATHNAME;
- the destination adds :IMPLEMENTATION, a directory naming the Lisp and its version, such as
  sbcl-2.6.8-win-x64/, as ASDF's own default translations do. Without it, a cache left by one
  SBCL version was loaded by the next, which stops with INVALID-FASL-VERSION;
- inherited configuration is ignored, so a translation in the user's own ASDF configuration
  cannot send a fasl elsewhere and mix the two modes."
  (format nil "(:output-translations ((:root :**/ :*.*.*) (~S :implementation :**/ :*.*.*)) :ignore-inherited-configuration)"
          (namestring cache)))

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
        (format *error-output* "~&with-mode: no such script: ~a~%" (human-path:human-path script-path))
        (uiop:quit 2))

      (let* ((translations (output-translations cache))
             (env (list* (format nil "COALTON_ENV=~A"
                                 (if (eq mode :release) "release" "development"))
                         (format nil "ASDF_OUTPUT_TRANSLATIONS=~A" translations)
                         (remove-if (lambda (e)
                                      (or (uiop:string-prefix-p "COALTON_ENV=" e)
                                          (uiop:string-prefix-p "ASDF_OUTPUT_TRANSLATIONS=" e)))
                                    (sb-ext:posix-environ)))))

        (format t "~&========== ~(~a~) mode ==========~%" mode)
        (format t "cache:  ~a~a~%" (uiop:native-namestring cache)
                (uiop:native-namestring (uiop:ensure-directory-pathname (uiop:implementation-identifier))))
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
