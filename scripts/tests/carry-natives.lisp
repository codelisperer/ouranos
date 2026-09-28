;;;; carry-natives.lisp --- an app's own native library travels with its bundle (#78)
;;;;
;;;; The tests take the shape of the failure: the app loads a library from its own directory,
;;;; the image is dumped into a bundle, the app's directory is deleted, and the bundle is run.
;;;; With scripts/carry-natives.lisp the app must still call the library, and the file it
;;;; opened must be the copy in the bundle.
;;;;
;;;; There are two controls, run through the same fixture:
;;;;
;;;;   - the same bundle with the carried copy deleted must fail, naming the file. Without
;;;;     this, a machine that could find the library some other way would pass the first
;;;;     test while the bundle carried nothing;
;;;;   - a dump that does not carry the library must fail once the app's directory is gone.
;;;;     That is the defect, and it shows the fixture can see it.
;;;;
;;;; The library is this tree's libuv, copied into the fixture under another name, so it is
;;;; not under vendor/ and nothing else on the machine has that name. libuv is used because
;;;; every CI leg builds it; where it has not been built the tests are skipped, and say so.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

(defun %built-libuv ()
  "The libuv this tree built under vendor/, or NIL."
  (loop for name in '("libuv.dll" "libuv.so.1" "libuv.1.dylib")
        for path = (probe-file (merge-pathnames (concatenate 'string "vendor/libuv/lib/" name) td-root))
        when path return path))

(defun %app-library-name ()
  (cond ((uiop:os-windows-p) "appnative.dll")
        ((uiop:os-macosx-p) "libappnative.dylib")
        (t "libappnative.so")))

(defun %carry-then-run (&key (carry t) (remove-carried nil))
  "Build an app directory holding a copy of libuv and a LICENSE, dump an image that loaded the
copy from there into a bundle directory (carrying it when CARRY), delete the app directory, and
run the bundle. REMOVE-CARRIED deletes the carried copy from the bundle before the run.
Returns (values RUN-OUTPUT DUMP-CODE RUN-CODE DUMP-OUTPUT BUNDLE-DIRECTORY-NAME)."
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/native/" tree)))
         (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
         (lib (merge-pathnames (%app-library-name) app))
         (image (merge-pathnames (if (uiop:os-windows-p) "app.exe" "app") bundle))
         (dump-out (make-string-output-stream))
         (run-out (make-string-output-stream)))
    (uiop:copy-file (%built-libuv) lib)
    (%write (merge-pathnames "LICENSE" app) "test license")
    (let* ((forms
             (list "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
                   "(asdf:load-system :cffi)"
                   (format nil "(load ~S)" (uiop:native-namestring (merge-pathnames "carry-natives.lisp" *scripts*)))
                   (format nil "(load ~S)" (uiop:native-namestring (merge-pathnames "dump-image.lisp" *scripts*)))
                   (format nil "(cffi:load-foreign-library ~S)" (uiop:native-namestring lib))
                   (if carry
                       (format nil "(ouranos-carry:carry-declared-libraries (list ~S) ~S)"
                               (uiop:native-namestring lib) (uiop:native-namestring bundle))
                       "t")
                   ;; What the app prints: the libuv version, which needs the library, and
                   ;; the file CFFI opened it from, which says which copy that was.
                   "(defun cl-user::carry-probe-main () (format t \"~&VERSION ~A~%\" (cffi:foreign-funcall \"uv_version\" :unsigned-int)) (dolist (l (cffi:list-foreign-libraries :loaded-only t)) (format t \"~&OPENED ~A~%\" (cffi:foreign-library-pathname l))) (finish-output) (uiop:quit 0))"
                   (format nil "(ouranos-dump:dump-executable ~S 'cl-user::carry-probe-main)"
                           (uiop:native-namestring image))))
           (dump-code
             (nth-value 2 (uiop:run-program
                           (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                         "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                                         "--eval" "(require :asdf)")
                                   (mapcan (lambda (f) (list "--eval" f)) forms))
                           :output dump-out :error-output dump-out :ignore-error-status t))))
      (uiop:delete-directory-tree (merge-pathnames "app/" tree) :validate t :if-does-not-exist :ignore)
      (when remove-carried
        (uiop:delete-file-if-exists (merge-pathnames (%app-library-name) bundle)))
      (let ((run-code
              (and (probe-file image)
                   (nth-value 2 (uiop:run-program (list (uiop:native-namestring image))
                                                  :output run-out :error-output run-out
                                                  :ignore-error-status t)))))
        (uiop:delete-directory-tree tree :validate t :if-does-not-exist :ignore)
        (values (get-output-stream-string run-out) dump-code run-code
                (get-output-stream-string dump-out)
                (car (last (pathname-directory bundle))))))))

(test carried-app-library-opens-from-beside-the-executable
  "#78: a library the app loaded from its own directory is carried into the bundle, and the
dumped app opens that copy when the app's directory no longer exists."
  (if (null (%built-libuv))
      (skip "vendor/libuv is not built here; run scripts/build-libuv.lisp")
      (multiple-value-bind (out dump-code run-code dump-out)
          (%carry-then-run)
        (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
        (is (search "carry     " dump-out) "the dump did not report carrying the library:~%~A" dump-out)
        (is (search "LICENSES/" dump-out) "the dump did not report carrying the license:~%~A" dump-out)
        (is (eql 0 run-code) "the app did not run:~%~A" out)
        (is (search "VERSION " out) "the app did not call the library:~%~A" out)
        (is (search (format nil "bundle/~A" (%app-library-name)) out)
            "the app must have opened the copy in the bundle:~%~A" out))))

(test carried-app-library-deleted-from-the-bundle-stops-the-app
  "The control for the test above: with the carried copy deleted, the app stops at startup
with exit code 3 and names the file. If it ran, the library came from somewhere other than
the bundle, and the test above would prove nothing."
  (if (null (%built-libuv))
      (skip "vendor/libuv is not built here; run scripts/build-libuv.lisp")
      (multiple-value-bind (out dump-code run-code dump-out)
          (%carry-then-run :remove-carried t)
        (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
        (is (eql 3 run-code) "the app must stop with code 3 without its carried library, got ~A:~%~A" run-code out)
        (is (search (%app-library-name) out) "the message must name the missing file:~%~A" out))))

(test uncarried-app-library-stops-the-app-once-its-directory-is-gone
  "The defect #78 describes, through the same fixture: without carrying, the dumped image
reopens the library from the app's directory, and fails when that directory is not there."
  (if (null (%built-libuv))
      (skip "vendor/libuv is not built here; run scripts/build-libuv.lisp")
      (multiple-value-bind (out dump-code run-code dump-out)
          (%carry-then-run :carry nil)
        (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
        (is (not (eql 0 run-code)) "an uncarried library must stop the app, or this fixture cannot see #78:~%~A" out)
        (is (not (search "VERSION " out)) "the app called a library it should not have been able to open:~%~A" out))))

;;; --- refusals, which need no dump ---------------------------------------------------

(defun %load-carry-natives ()
  (unless (find-package "OURANOS-CARRY")
    (load (merge-pathnames "carry-natives.lisp" *scripts*))))

(defun %carry-refusal (paths &rest keys)
  "The CARRY-REFUSED condition CARRY-DECLARED-LIBRARIES signals for PATHS, or NIL, and the
bundle directory, which must be empty when it refuses."
  (%load-carry-natives)
  (let ((bundle (merge-pathnames "bundle/" (%fresh-tree))))
    (values (handler-case (progn (apply (find-symbol "CARRY-DECLARED-LIBRARIES" "OURANOS-CARRY")
                                        paths bundle :report (make-broadcast-stream) keys)
                                 nil)
              (error (e) e))
            bundle)))

(test carry-refuses-a-missing-file
  (let ((e (%carry-refusal (list (merge-pathnames "no-such-library.dll" (%fresh-tree))))))
    (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
    (is (search "does not exist" (princ-to-string e)))))

(test carry-refuses-a-library-with-no-license-text
  (let* ((dir (ensure-directories-exist (merge-pathnames "a/b/" (%fresh-tree))))
         (lib (merge-pathnames "thing.dll" dir)))
    (%write lib "not really a library")
    (multiple-value-bind (e bundle) (%carry-refusal (list lib))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
      (is (search "LICENSE" (princ-to-string e)))
      (is (null (probe-file (merge-pathnames "thing.dll" bundle))) "nothing may be copied when it refuses"))
    ;; The control: the same file with a LICENSE in the directory above is carried.
    (%write (merge-pathnames "../LICENSE" dir) "license")
    (multiple-value-bind (e bundle) (%carry-refusal (list lib))
      (is (null e) "with a license above it, it must be carried: ~A" e)
      (is (probe-file (merge-pathnames "thing.dll" bundle)))
      (is (probe-file (merge-pathnames "LICENSES/thing-LICENSE" bundle))))))

(test carry-refuses-two-libraries-with-one-file-name
  (let* ((tree (%fresh-tree))
         (one (merge-pathnames "one/thing.dll" tree))
         (two (merge-pathnames "two/thing.dll" tree)))
    (dolist (f (list one two))
      (%write f "x")
      (%write (merge-pathnames "LICENSE" (uiop:pathname-directory-pathname f)) "license"))
    (let ((e (%carry-refusal (list one two))))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
      (is (search "same file name" (princ-to-string e))))))

(test carry-refuses-a-library-under-vendor
  (let* ((tree (%fresh-tree))
         (vendor (merge-pathnames "vendor/" tree))
         (lib (merge-pathnames "libx/lib/x.dll" vendor)))
    (%write lib "x")
    (%write (merge-pathnames "../LICENSE" (uiop:pathname-directory-pathname lib)) "license")
    (let ((e (%carry-refusal (list lib) :vendor vendor)))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
      (is (search "vendor/" (princ-to-string e))))))

(test declared-carry-paths-reads-every-carry-flag
  (%load-carry-natives)
  (is (equal '("a.dll" "b/c.dll")
             (funcall (find-symbol "DECLARED-CARRY-PATHS" "OURANOS-CARRY")
                      '("--system" "x" "--carry" "a.dll" "--name" "n" "--carry" "b/c.dll")))))
