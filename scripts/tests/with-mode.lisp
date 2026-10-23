;;;; with-mode.lisp --- scripts/with-mode.lisp runs on every operating system and keeps one cache per SBCL (#572)
;;;;
;;;; The test runs the real script, in development mode, on a fixture: a one-file system in a fresh
;;;; directory and a script that loads it and prints where its fasl went. OURANOS_WITH_MODE_CACHE
;;;; points the caches at a fresh directory, so nothing is written to the user's ~/.cache.
;;;;
;;;; It checks the two faults #572 found. On Windows, the first file compiled under the old
;;;; translations failed in TRANSLATE-PATHNAME, so the run itself failed. Everywhere, the fasl went
;;;; straight under the mode's cache with no directory naming the SBCL version, so a cache left by
;;;; another SBCL was loaded. The control is the old translations, which fail the run on Windows
;;;; and put the fasl outside an implementation directory elsewhere.

(in-package #:checkers/tests)

(in-suite checkers)

(test with-mode-runs-a-script-and-puts-its-fasls-under-the-sbcl-version
  (let* ((tree (%fresh-tree))
         (src (uiop:ensure-directory-pathname (merge-pathnames "src/" tree)))
         (cache (uiop:ensure-directory-pathname (merge-pathnames "cache/" tree)))
         (probe (merge-pathnames "probe.lisp" tree)))
    (ensure-directories-exist src)
    (ensure-directories-exist cache)
    (with-open-file (o (merge-pathnames "wmprobe.asd" src) :direction :output)
      (write-line "(defsystem \"wmprobe\" :components ((:file \"a\")))" o))
    (with-open-file (o (merge-pathnames "a.lisp" src) :direction :output)
      (write-line "(defun wmprobe-x () 1)" o))
    (with-open-file (o probe :direction :output)
      (format o "(require :asdf)~%(asdf:initialize-source-registry '(:source-registry (:directory ~S) :ignore-inherited-configuration))~%(asdf:load-system \"wmprobe\")~%(format t \"~~&fasl: ~~A~~%\" (namestring (first (asdf:output-files 'asdf:compile-op (asdf:find-component \"wmprobe\" \"a\")))))~%"
              (namestring src)))
    (multiple-value-bind (out err code)
        (uiop:run-program (list (namestring sb-ext:*runtime-pathname*) "--script"
                                (uiop:native-namestring (merge-pathnames "with-mode.lisp" *scripts*))
                                "dev" (uiop:native-namestring probe))
                          :output :string :error-output :output :ignore-error-status t
                          :environment (cons (format nil "OURANOS_WITH_MODE_CACHE=~A"
                                                     (uiop:native-namestring cache))
                                             (remove-if (lambda (e) (uiop:string-prefix-p "OURANOS_WITH_MODE_CACHE=" e))
                                                        (sb-ext:posix-environ))))
      (declare (ignore err))
      (is (= 0 code) "with-mode exited ~D:~%~A" code out)
      (let* ((at (search "fasl: " out))
             (fasl (and at (string-trim '(#\Space #\Return #\Newline)
                                        (subseq out (+ at 6) (position #\Newline out :start at)))))
             (expected (namestring (merge-pathnames (format nil "fasl-development/~A/"
                                                            (uiop:implementation-identifier))
                                                    (truename cache)))))
        (is-true fasl "the probe printed no fasl path:~%~A" out)
        (is (and fasl (uiop:string-prefix-p (string-downcase expected) (string-downcase fasl)))
            "the fasl ~A is not under ~A" fasl expected)))))
