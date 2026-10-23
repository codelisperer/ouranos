;;;; dyld-libraries.lisp --- verify-bundle-macos.sh judges a library by its last dyld state (#783)
;;;;
;;;; The rules are in scripts/dyld-libraries.lisp; scripts/check-dyld-log.lisp is what
;;;; verify-bundle-macos.sh runs. The fixtures under tests/dyld/ are real DYLD_PRINT_LIBRARIES
;;;; transcripts from macOS 26.6, trimmed to the lines about the processes, libSystem,
;;;; CoreFoundation, libcurl, libssl and libcrypto, with the directory they ran in replaced by
;;;; /Applications. The programs were a C program that dlopens its arguments, copied into
;;;; "Example App.app/Contents/MacOS" as sbcl and as hyperion-view, and a launcher that execs it:
;;;;   unused.txt             sbcl opened nothing;
;;;;   opened-directly.txt    sbcl opened /usr/lib/libssl.48.dylib, as cl+ssl does when it finds
;;;;                          no other OpenSSL;
;;;;   opened-by-webkit.txt   hyperion-view opened WebKit.framework;
;;;;   carried-after-exec.txt the launcher `example' exec'd sbcl, which opened the bundle's own
;;;;                          libcrypto.3.dylib.

(in-package #:checkers/tests)

(in-suite checkers)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "dyld-libraries.lisp" *scripts*)))

(defparameter +example-bundle+ "/Applications/Example App.app/Contents/MacOS")

(defun %dyld-fixture-path (name)
  (merge-pathnames (concatenate 'string "tests/dyld/" name ".txt") *scripts*))

(defun %dyld-fixture (name)
  (uiop:read-file-string (%dyld-fixture-path name)))

(defun %verdicts-of (text &optional (bundle +example-bundle+))
  "The verdict of each loaded libssl or libcrypto in the dyld log TEXT."
  (mapcar #'first (ouranos-dyld-libraries:openssl-findings
                   (ouranos-dyld-libraries:parse-dyld-log text) bundle)))

(defun %openssl-verdicts (name &optional (bundle +example-bundle+))
  "Each (VERDICT PROCESS PATH) the rules give for the fixture NAME."
  (mapcar (lambda (f) (list (first f) (second f) (fourth f)))
          (ouranos-dyld-libraries:openssl-findings
           (ouranos-dyld-libraries:parse-dyld-log (%dyld-fixture name)) bundle)))

(defun %path-lines-naming-openssl (text)
  "What verify-bundle-macos.sh did before #783: every dyld line naming a libssl or libcrypto
with a path, whatever happened to it afterwards."
  (with-input-from-string (in text)
    (loop for line = (read-line in nil)
          while line
          when (and (search "dyld" line) (search "> /" line)
                    (or (search "/libssl." line) (search "/libcrypto." line)))
            collect line)))

(test a-library-dyld-moved-to-delayed-was-not-loaded
  "A process that never used Apple's libssl still gets a path line for it. The rules read the
move that follows and report nothing. CONTROL: reading path lines alone, as the script did
before, reports both libraries, which is the false report on #781."
  (let ((text (%dyld-fixture "unused")))
    (is (null (%openssl-verdicts "unused")))
    (is (= 2 (length (%path-lines-naming-openssl text)))
        "control: the path lines are in the fixture")
    (let ((ssl (find "/usr/lib/libssl.48.dylib"
                     (ouranos-dyld-libraries:parse-dyld-log text)
                     :key #'ouranos-dyld-libraries:image-path :test #'string=)))
      (is (and ssl (eq :delayed (ouranos-dyld-libraries:image-state ssl)))))))

(test apples-openssl-opened-by-the-app-fails-and-opened-by-webkit-passes
  "The same two libraries, moved back to loaded. In sbcl, which is the app's Lisp process,
that is a FAIL. In hyperion-view it is WebKit's own and passes. CONTROL: the WebKit
transcript with its process renamed to sbcl fails, so it passes because of the process."
  (is (equal '((:fail "sbcl" "/usr/lib/libcrypto.46.dylib")
               (:fail "sbcl" "/usr/lib/libssl.48.dylib"))
             (%openssl-verdicts "opened-directly")))
  (is (equal '((:webkit "hyperion-view" "/usr/lib/libcrypto.46.dylib")
               (:webkit "hyperion-view" "/usr/lib/libssl.48.dylib"))
             (%openssl-verdicts "opened-by-webkit")))
  (is (equal '(:fail :fail)
             (%verdicts-of (uiop:frob-substrings (%dyld-fixture "opened-by-webkit")
                                                 '("hyperion-view") "sbcl")))))

(test a-carried-library-passes-and-exec-starts-a-new-process
  "The launcher execs sbcl under the same pid; the images after sbcl's path line belong to sbcl.
The bundle's libcrypto passes, and the same file judged against another bundle fails."
  (let* ((text (%dyld-fixture "carried-after-exec"))
         (images (ouranos-dyld-libraries:parse-dyld-log text)))
    (is (equal '("example" "sbcl")
               (remove-duplicates (mapcar #'ouranos-dyld-libraries:image-process images)
                                  :test #'string= :from-end t)))
    (is (= 1 (length (remove-duplicates (mapcar #'ouranos-dyld-libraries:image-pid images)))))
    (is (equal `((:carried "sbcl" ,(concatenate 'string +example-bundle+ "/libcrypto.3.dylib")))
               (%openssl-verdicts "carried-after-exec")))
    (is (equal '(:fail) (%verdicts-of text "/Applications/Other.app/Contents/MacOS")))))

(test check-dyld-log-exits-by-the-openssl-verdict
  "The script verify-bundle-macos.sh runs: exit 1 on a FAIL, 0 when every loaded OpenSSL is
excused or none is, 2 on a bad command line; `loaded' lists only libraries still loaded."
  (flet ((check-dyld-log (&rest args)
           (multiple-value-bind (out err code)
               (uiop:run-program
                (list* (uiop:native-namestring sb-ext:*runtime-pathname*) "--script"
                       (uiop:native-namestring (merge-pathnames "check-dyld-log.lisp" *scripts*))
                       args)
                :input nil :output :string :error-output :string :ignore-error-status t)
             (declare (ignore err))
             (values code out)))
         (fixture (name)
           (uiop:native-namestring (%dyld-fixture-path name))))
    (is (eql 1 (check-dyld-log "openssl" (fixture "opened-directly") +example-bundle+)))
    (is (eql 0 (check-dyld-log "openssl" (fixture "opened-by-webkit") +example-bundle+)))
    (is (eql 0 (check-dyld-log "openssl" (fixture "unused") +example-bundle+)))
    (is (eql 2 (check-dyld-log "openssl" (fixture "unused"))))
    (multiple-value-bind (code out) (check-dyld-log "loaded" (fixture "unused"))
      (is (eql 0 code))
      (is (search (format nil "sbcl~C/usr/lib/libSystem.B.dylib" #\Tab) out))
      (is (not (search "libssl" out)) "a delayed library is not listed: ~A" out))))
