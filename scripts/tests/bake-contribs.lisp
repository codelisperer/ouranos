;;;; bake-contribs.lisp --- a contrib that does not load stops the dump (#1099).
;;;;
;;;; Each test loads scripts/bake-contribs.lisp in a fresh sbcl, because REQUIRE of a contrib
;;;; this image already has returns at once and could not fail. The failing cases are a
;;;; contrib that does not exist, and a real contrib with SBCL_HOME pointing at a home whose
;;;; contrib/ directory is empty, which is what a bootstrap would meet if SBCL looked for its
;;;; contribs in the wrong place. The control for both is the real list under the real home.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

(defun %bake-child (form &key sbcl-home)
  "Run FORM, a string, in a fresh sbcl after loading scripts/bake-contribs.lisp. With
SBCL-HOME, the child's SBCL_HOME is that directory; its core is passed with --core, since the
runtime would otherwise look for it there. Returns (values exit-code output)."
  (let ((out (make-string-output-stream)))
    (values
     (nth-value 2 (uiop:run-program
                   (list (namestring sb-ext:*runtime-pathname*)
                         "--core" (namestring sb-ext:*core-pathname*)
                         "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
                         "--eval" (format nil "(load ~S)"
                                          (namestring (merge-pathnames "bake-contribs.lisp"
                                                                       *scripts*)))
                         "--eval" form)
                   :output out :error-output out :ignore-error-status t
                   :environment
                   (append (when sbcl-home
                             (list (format nil "SBCL_HOME=~A" (uiop:native-namestring sbcl-home))))
                           (remove-if (lambda (e)
                                        (and sbcl-home (uiop:string-prefix-p "SBCL_HOME=" e)))
                                      (%environment-with '())))))
     (get-output-stream-string out))))

(test every-contrib-a-dumped-image-carries-loads-here
  "The control: the real list under this SBCL's own home loads, exits 0, and leaves every
contrib on *MODULES*."
  (multiple-value-bind (code output)
      (%bake-child "(progn (ouranos-bake:bake-contribs-or-die \"t\" \"img\")
                           (dolist (c ouranos-bake:+contribs+)
                             (format t \"~(~A~)=~A~%\" c
                                     (and (member (string c) *modules* :test #'string-equal) t))))")
    (is (= 0 code) "exit was ~D~%~A" code output)
    (dolist (c '("asdf" "sb-cltl2" "sb-bsd-sockets" "sb-posix" "sb-rotate-byte" "sb-md5"
                 "sb-introspect" "sb-concurrency"))
      (is (search (format nil "~A=T" c) output) "~A is not on *MODULES*:~%~A" c output))
    (is (not (search "cannot dump" output)) "~A" output)))

(test a-contrib-that-does-not-exist-stops-the-dump-and-is-named
  "#1099: the bake used IGNORE-ERRORS, so a contrib that did not load was dumped as missing.
Now it exits 1 and names the contrib, the SBCL version and SBCL_HOME."
  (multiple-value-bind (code output)
      (%bake-child "(ouranos-bake:bake-contribs-or-die \"t\" \"img\" '(:sb-posix :sb-cons-1099-no-such))")
    (is (= 1 code) "exit was ~D~%~A" code output)
    (is (search "t: cannot dump img: 1 SBCL contrib it must carry did not load" output) "~A" output)
    (is (search "sb-cons-1099-no-such:" output) "the contrib is not named:~%~A" output)
    (is (not (search "sb-posix:" output)) "a contrib that loaded was named:~%~A" output)
    (is (search "SBCL_HOME is" output) "~A" output)
    (is (search "repair or reinstall sbcl" (string-downcase output)) "no advice:~%~A" output)))

(test a-real-contrib-under-an-empty-sbcl-home-stops-the-dump
  "A contrib SBCL cannot find because SBCL_HOME points at the wrong directory. sb-sprof is not
loaded by --non-interactive, so the child really has to find it on disk. Run with this SBCL's
own home it loads, which is the control.

The home has an empty contrib/ directory. SBCL uses SBCL_HOME only when it holds contrib/, and
otherwise falls back to the home beside its runtime (SB-IMPL::%SBCL-HOMEDIR-PATHNAME, SBCL
2.6.9). With a directory holding nothing, the Linux and Windows legs fell back to the real
install and loaded sb-sprof; macOS failed only because Homebrew's runtime has no home beside it."
  (let ((empty (%fresh-tree))
        (form "(ouranos-bake:bake-contribs-or-die \"t\" \"img\" '(:sb-sprof))"))
    (ensure-directories-exist (merge-pathnames "contrib/" empty))
    (multiple-value-bind (code output) (%bake-child form :sbcl-home empty)
      (is (= 1 code) "exit was ~D~%~A" code output)
      (is (search "sb-sprof:" output) "~A" output)
      (is (search (uiop:native-namestring empty) output) "SBCL_HOME is not shown:~%~A" output)
      (is (search "SBCL uses SBCL_HOME as its home" output) "~A" output)
      (is (search "unset SBCL_HOME or correct it" output) "~A" output))
    (multiple-value-bind (code output) (%bake-child form)
      (is (= 0 code) "with this SBCL's own home, exit was ~D~%~A" code output))))

(test an-sbcl-home-without-contrib-is-named-as-unused
  "Review of #1100: with SBCL_HOME set to a directory with no contrib/, SBCL does not use it,
and the advice says so and still says to unset or correct it. The contrib does not exist, so
the dump stops wherever SBCL found its home."
  (multiple-value-bind (code output)
      (%bake-child "(ouranos-bake:bake-contribs-or-die \"t\" \"img\" '(:sb-cons-1099-no-such))"
                   :sbcl-home (%fresh-tree))
    (is (= 1 code) "exit was ~D~%~A" code output)
    (is (search "SBCL_HOME has no contrib/ directory, so SBCL did not use it" output) "~A" output)
    (is (not (search "SBCL uses SBCL_HOME as its home" output)) "~A" output)))

(test bootstrap-and-the-desktop-build-use-the-checked-bake
  "Both images that carry contribs bake them through bake-contribs.lisp, and neither still
ignores a contrib that fails. The bake comes before (require :asdf): ASDF is a contrib, and
with the contrib directory wrong that REQUIRE would stop the script before the check could
say why (review of #1100)."
  (dolist (file (list (merge-pathnames "bootstrap.lisp" td-root)
                      (merge-pathnames "build-desktop-app.lisp" *scripts*)))
    (let ((text (uiop:read-file-string file)))
      (is (search "bake-contribs.lisp" text) "~A does not load it" file)
      (is (search "ouranos-bake:bake-contribs-or-die" text) "~A does not call it" file)
      (is (not (search "(ignore-errors (require contrib))" text)) "~A still ignores it" file)
      (let ((bake (search "ouranos-bake:bake-contribs-or-die" text))
            (asdf (search (format nil "~%(require :asdf)") text)))
        (is-true (and bake asdf (< bake asdf)) "~A requires ASDF before the bake" file)))))
