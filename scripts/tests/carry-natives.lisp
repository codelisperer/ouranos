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

(defun %alias-file-name ()
  (cond ((uiop:os-windows-p) "libappalias.dll")
        ((uiop:os-macosx-p) "libappalias.dylib")
        (t "libappalias.so")))

(defun %search-path-environment (dir)
  "This process's environment with DIR first on the path the OS loader searches for a bare
library name."
  (let ((var (cond ((uiop:os-windows-p) "PATH")
                   ((uiop:os-macosx-p) "DYLD_LIBRARY_PATH")
                   (t "LD_LIBRARY_PATH")))
        (sep (if (uiop:os-windows-p) ";" ":")))
    (cons (format nil "~A=~A~@[~A~A~]" var (uiop:native-namestring dir) (and (uiop:getenv var) sep) (uiop:getenv var))
          (remove-if (lambda (e) (uiop:string-prefix-p (format nil "~A=" var) e)) (sb-ext:posix-environ)))))

(defun %carry-then-run (&key (carry t) (remove-carried nil) (alias nil) (no-definition-match nil))
  "Build an app directory holding a copy of libuv and a LICENSE, dump an image that loaded the
copy from there into a bundle directory (carrying it when CARRY), delete the app directory, and
run the bundle. REMOVE-CARRIED deletes the carried copy from the bundle before the run.

ALIAS is cl-sqlite's case. The app directory also holds the library as libappalias, a CFFI
definition lists libappalias first and appnative second, and the image opens it by bare name
through the loader's search path, so it opens libappalias. The carried file is appnative.
NO-DEFINITION-MATCH makes the carry step ignore that definition, which is the control.

Returns (values RUN-OUTPUT DUMP-CODE RUN-CODE DUMP-OUTPUT BUNDLE-DIRECTORY-NAME)."
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/native/" tree)))
         (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
         (lib (merge-pathnames (%app-library-name) app))
         (image (merge-pathnames (if (uiop:os-windows-p) "app.exe" "app") bundle))
         (dump-out (make-string-output-stream))
         (run-out (make-string-output-stream)))
    (uiop:copy-file (%built-libuv) lib)
    (when alias
      (uiop:copy-file (%built-libuv) (merge-pathnames (%alias-file-name) app)))
    (%write (merge-pathnames "LICENSE" app) "test license")
    (let* ((forms
             (list "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
                   "(asdf:load-system :cffi)"
                   (format nil "(load ~S)" (uiop:native-namestring (merge-pathnames "carry-natives.lisp" *scripts*)))
                   (format nil "(load ~S)" (uiop:native-namestring (merge-pathnames "dump-image.lisp" *scripts*)))
                   (if alias
                       (format nil "(progn (cffi:define-foreign-library appalias (t (:or (:default ~S) (:default ~S)))) (cffi:use-foreign-library appalias))"
                               (pathname-name (%alias-file-name)) (pathname-name (%app-library-name)))
                       (format nil "(cffi:load-foreign-library ~S)" (uiop:native-namestring lib)))
                   (if no-definition-match
                       "(defun ouranos-carry::%spec-file-names (lib) (declare (ignore lib)) nil)"
                       "t")
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
                           :output dump-out :error-output dump-out :ignore-error-status t
                           :environment (if alias (%search-path-environment app) (sb-ext:posix-environ))))))
      (aion/fs:delete-tree (merge-pathnames "app/" tree) :if-does-not-exist :ignore)
      (when remove-carried
        (uiop:delete-file-if-exists (merge-pathnames (%app-library-name) bundle)))
      (let ((run-code
              (and (probe-file image)
                   (nth-value 2 (uiop:run-program (list (uiop:native-namestring image))
                                                  :output run-out :error-output run-out
                                                  :ignore-error-status t)))))
        (aion/fs:delete-tree tree :if-does-not-exist :ignore)
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

(test a-library-opened-under-another-name-in-its-definition-is-carried
  "cl-sqlite's case: the image opened libappalias by bare name, and the app carries appnative,
which the same CFFI definition lists. The carried copy must be what the app opens once the
app directory is gone."
  (if (null (%built-libuv))
      (skip "vendor/libuv is not built here; run scripts/build-libuv.lisp")
      (multiple-value-bind (out dump-code run-code dump-out)
          (%carry-then-run :alias t)
        (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
        (is (search "opened beside the executable" dump-out) "the carry did not match the open library:~%~A" dump-out)
        (is (eql 0 run-code) "the app did not run:~%~A" out)
        (is (search (format nil "bundle/~A" (%app-library-name)) out)
            "the app must have opened the carried copy:~%~A" out))))

(test a-library-opened-under-another-name-is-missed-without-its-definition
  "The control for the test above: with the definition ignored, the carry does not match the
library the image opened, SBCL reopens libappalias by bare name when the app starts, and with
the app directory gone that fails."
  (if (null (%built-libuv))
      (skip "vendor/libuv is not built here; run scripts/build-libuv.lisp")
      (multiple-value-bind (out dump-code run-code dump-out)
          (%carry-then-run :alias t :no-definition-match t)
        (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
        (is (search "not open in this image" dump-out) "without the definition the carry must not match:~%~A" dump-out)
        (is (not (eql 0 run-code)) "the app must fail without the library it opened by bare name:~%~A" out))))

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

(defun %carry-fn (name)
  (%load-carry-natives)
  (fdefinition (find-symbol name "OURANOS-CARRY")))

(test declared-carries-pairs-each-carry-with-the-licenses-after-it
  (let ((argv '("--system" "x" "--carry" "a.dll" "--name" "n"
                "--carry" "b/sqlite3.dll" "--carry-license" "pd.txt" "--carry-license" "more.txt")))
    (is (equal '(("a.dll") ("b/sqlite3.dll" "pd.txt" "more.txt"))
               (funcall (%carry-fn "DECLARED-CARRIES") argv)))
    ;; A build re-run under a patched runtime gets the same declarations back.
    (is (equal (funcall (%carry-fn "DECLARED-CARRIES") argv)
               (funcall (%carry-fn "DECLARED-CARRIES")
                        (funcall (%carry-fn "CARRY-ARGUMENTS")
                                 (funcall (%carry-fn "DECLARED-CARRIES") argv)))))))

(test a-carry-license-before-any-carry-is-refused
  (let ((e (handler-case (progn (funcall (%carry-fn "DECLARED-CARRIES") '("--carry-license" "pd.txt")) nil)
             (error (e) e))))
    (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)))

(test a-named-license-carries-a-library-with-none-beside-it
  ;; SQLite is public domain and ships no license file; the build names the note it writes.
  (let* ((tree (%fresh-tree))
         (lib (merge-pathnames "dll/sqlite3.dll" tree))
         (note (merge-pathnames "notes/sqlite-PUBLIC-DOMAIN.txt" tree)))
    (%write lib "x")
    (%write note "public domain")
    (multiple-value-bind (e bundle) (%carry-refusal (list (list lib note)))
      (is (null e) "a named license must be accepted: ~A" e)
      (is (probe-file (merge-pathnames "sqlite3.dll" bundle)))
      (is (probe-file (merge-pathnames "LICENSES/sqlite3-sqlite-PUBLIC-DOMAIN.txt" bundle))))
    (let ((e (%carry-refusal (list (list lib (merge-pathnames "notes/missing.txt" tree))))))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "a missing named license must be refused, got ~A" e))))

(test a-license-directory-is-carried-whole
  ;; PDFium's layout: win-x64/bin/pdfium.dll, win-x64/LICENSE, and third-party notices in
  ;; win-x64/licenses/. The directory is copied with what is inside it.
  (let* ((tree (%fresh-tree))
         (lib (merge-pathnames "win-x64/bin/pdfium.dll" tree)))
    (%write lib "x")
    (%write (merge-pathnames "win-x64/LICENSE" tree) "bsd")
    (%write (merge-pathnames "win-x64/licenses/abseil.txt" tree) "apache")
    (%write (merge-pathnames "win-x64/licenses/sub/zlib.txt" tree) "zlib")
    (multiple-value-bind (e bundle) (%carry-refusal (list lib))
      (is (null e) "got ~A" e)
      (is (probe-file (merge-pathnames "LICENSES/pdfium-LICENSE" bundle)))
      (is (probe-file (merge-pathnames "LICENSES/pdfium-licenses/abseil.txt" bundle)))
      (is (probe-file (merge-pathnames "LICENSES/pdfium-licenses/sub/zlib.txt" bundle))))))

;;; --- the tree's SQLite, carried when the app loads cl-sqlite (#899) ---------------------
;;;
;;; TREE-SQLITE-CARRY decides; CARRY-DECLARED-LIBRARIES carries. Each test gives the decision
;;; a fresh vendor/ directory, and LOADED stands in for cl-sqlite being open in the image, so
;;; the tests do not depend on what this machine has built. The end-to-end check, a built
;;; bundle running praxeon's retrieval on the carried copy, is the sqlite-probe job in
;;; desktop-release.yml.

(defun %tree-sqlite-carry (vendor carries &rest keys)
  "(values TREE-CARRIES NOTE CONDITION) from TREE-SQLITE-CARRY."
  (handler-case (multiple-value-bind (carries note)
                    (apply (%carry-fn "TREE-SQLITE-CARRY") vendor carries keys)
                  (values carries note nil))
    (error (e) (values nil nil e))))

(defun %build-fake-sqlite (vendor platform &key (license t) (stamp "9.9.9"))
  "Write vendor/sqlite/lib/<the platform's name>, vendor/sqlite/LICENSE when LICENSE, a
sqlite.pin for version 9.9.9 in the directory above VENDOR, and vendor/sqlite/BUILT-FROM naming
version STAMP with the pin's sha256 when STAMP is a string. The stamp's form is the one
build-sqlite.lisp writes."
  (let ((lib (merge-pathnames (concatenate 'string "sqlite/lib/"
                                           (funcall (%carry-fn "SQLITE-FILE-NAME") platform))
                              vendor))
        (built-from (merge-pathnames "sqlite/BUILT-FROM" vendor)))
    (%write lib "not really sqlite")
    (when license (%write (merge-pathnames "sqlite/LICENSE" vendor) "public domain"))
    (%write (merge-pathnames "sqlite.pin" (uiop:pathname-parent-directory-pathname vendor))
            (format nil "# a test pin~%version 9.9.9~%sha256  ABCD~%"))
    (if stamp
        (%write built-from (format nil "version ~A~%sha256 abcd~%" stamp))
        (uiop:delete-file-if-exists built-from))
    lib))

(test the-tree-sqlite-is-carried-only-when-the-app-loads-cl-sqlite
  (let ((vendor (merge-pathnames "vendor/" (%fresh-tree))))
    (%build-fake-sqlite vendor :macos)
    (multiple-value-bind (carries note e) (%tree-sqlite-carry vendor '() :loaded nil :platform :macos)
      (is (null e) "got ~A" e)
      (is (null carries) "an app without cl-sqlite carries no SQLite")
      (is (null note)))
    (multiple-value-bind (carries note e) (%tree-sqlite-carry vendor '() :loaded t :platform :macos)
      (is (null e) "got ~A" e)
      (is (null note))
      (is (= 1 (length carries)))
      (is (equal (probe-file (first (first carries)))
                 (probe-file (merge-pathnames "sqlite/lib/libsqlite3.dylib" vendor))))
      (is (equal (probe-file (second (first carries)))
                 (probe-file (merge-pathnames "sqlite/LICENSE" vendor)))))))

(test the-tree-sqlite-has-the-file-name-cl-sqlite-asks-for-on-each-platform
  ;; cl-sqlite's definition: libsqlite3 on darwin, libsqlite3.so.0 or .so on other Unixes,
  ;; libsqlite3.dll or sqlite3.dll on Windows. Carrying another name would leave the image's
  ;; own library unmatched (%MATCHING-OPEN-LIBRARIES), and SBCL would reopen it by bare name.
  (loop for (platform name) in '((:macos "libsqlite3.dylib") (:linux "libsqlite3.so.0")
                                 (:windows "sqlite3.dll"))
        do (let ((vendor (merge-pathnames "vendor/" (%fresh-tree))))
             (%build-fake-sqlite vendor platform)
             (let ((carries (%tree-sqlite-carry vendor '() :loaded t :platform platform)))
               (is (equal name (file-namestring (first (first carries))))
                   "~A: carried ~A" platform (first (first carries)))))))

(test the-bundle-build-stops-with-the-command-when-the-tree-sqlite-is-not-built
  (let ((vendor (merge-pathnames "vendor/" (%fresh-tree))))
    (multiple-value-bind (carries note e) (%tree-sqlite-carry vendor '() :loaded t :platform :linux)
      (declare (ignore note))
      (is (null carries))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
      (is (search "sbcl --script" (princ-to-string e)) "~A" e)
      (is (search "build-sqlite.lisp" (princ-to-string e)) "~A" e))
    ;; The library without its LICENSE is refused too: the bundle carries the licence text.
    (%build-fake-sqlite vendor :linux :license nil)
    (let ((e (nth-value 2 (%tree-sqlite-carry vendor '() :loaded t :platform :linux))))
      (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "got ~A" e)
      (is (search "LICENSE" (princ-to-string e)) "~A" e))
    ;; Built from another release than the pin names, or with no stamp: refused, with the
    ;; command, which rebuilds it.
    (dolist (stamp '("9.9.8" nil))
      (%build-fake-sqlite vendor :linux :stamp stamp)
      (let ((e (nth-value 2 (%tree-sqlite-carry vendor '() :loaded t :platform :linux))))
        (is (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) "stamp ~A: got ~A" stamp e)
        (is (search "not built from the release sqlite.pin names" (princ-to-string e)) "~A" e)
        (is (search "build-sqlite.lisp" (princ-to-string e)) "~A" e)))
    ;; The control: once both are there, built from the pin's release, it is carried.
    (%build-fake-sqlite vendor :linux)
    (multiple-value-bind (carries note e) (%tree-sqlite-carry vendor '() :loaded t :platform :linux)
      (declare (ignore note))
      (is (null e) "got ~A" e)
      (is (= 1 (length carries))))))

(test an-app-that-carries-its-own-sqlite-keeps-it
  (let ((vendor (merge-pathnames "vendor/" (%fresh-tree))))
    (%build-fake-sqlite vendor :windows)
    (multiple-value-bind (carries note e)
        (%tree-sqlite-carry vendor '(("C:/app/dll/sqlite3.dll" "C:/app/notes/pd.txt"))
                            :loaded t :platform :windows)
      (is (null e) "got ~A" e)
      (is (null carries) "the tree's copy must not be carried beside the app's own")
      (is (search "carries its own" (or note "")) "note: ~A" note))))

(test a-tree-carry-may-come-from-vendor
  ;; The app's --carry of a file under vendor/ is refused (CARRY-REFUSES-A-LIBRARY-UNDER-VENDOR);
  ;; the tree's own SQLite comes from there and is carried, with its licence.
  (let* ((tree (%fresh-tree))
         (vendor (merge-pathnames "vendor/" tree))
         (lib (%build-fake-sqlite vendor :linux)))
    (multiple-value-bind (e bundle)
        (%carry-refusal '() :vendor vendor
                            :tree-carries (list (list (uiop:native-namestring lib)
                                                      (uiop:native-namestring
                                                       (merge-pathnames "sqlite/LICENSE" vendor)))))
      (is (null e) "got ~A" e)
      (is (probe-file (merge-pathnames "libsqlite3.so.0" bundle)))
      (is (probe-file (merge-pathnames "LICENSES/libsqlite3.so-LICENSE" bundle))))))

;;; --- macOS: carried libraries that link each other (#78, the macOS follow-up) ----------
;;;
;;; A dylib records each library it needs by that library's install name, an absolute path
;;; for anything built outside an app bundle. So a carried libssl still asked for Homebrew's
;;; libcrypto, and the bundle failed on a Mac without Homebrew although it carried libcrypto
;;; too (measured on #334). The fixture reproduces the shape with two dylibs compiled here: A
;;; needs B by B's absolute install name. Both are carried, their directory is deleted, and A
;;; is loaded from the bundle in a fresh image. These need macOS and a C compiler; elsewhere they
;;; are skipped, and say why.

(defun %dylib-pair (dir)
  "Compile libfixb.dylib and libfixa.dylib in DIR, A needing B by B's absolute install name,
and sign both with codesign, as Homebrew's libraries are. Returns true when both were built.

The codesign is what makes the fixture as hard as the real case. cc leaves a `linker-signed'
ad-hoc signature, which install_name_tool refreshes by itself, so a fixture left like that
passes even when the carry step never re-signs. A signature made by codesign is only
invalidated by install_name_tool, and arm64 will not load the result, so re-signing matters."
  (let ((b (merge-pathnames "b.c" dir)) (a (merge-pathnames "a.c" dir))
        (libb (merge-pathnames "libfixb.dylib" dir)) (liba (merge-pathnames "libfixa.dylib" dir)))
    (%write b "int fixb(void) { return 42; }")
    (%write a "int fixb(void); int fixa(void) { return fixb() + 1; }")
    (and (eql 0 (nth-value 2 (uiop:run-program
                              (list "cc" "-dynamiclib" "-o" (uiop:native-namestring libb) (uiop:native-namestring b)
                                    "-install_name" (uiop:native-namestring libb))
                              :ignore-error-status t :output nil :error-output nil)))
         (eql 0 (nth-value 2 (uiop:run-program
                              (list "cc" "-dynamiclib" "-o" (uiop:native-namestring liba) (uiop:native-namestring a)
                                    "-L" (uiop:native-namestring dir) "-lfixb"
                                    "-install_name" (uiop:native-namestring liba))
                              :ignore-error-status t :output nil :error-output nil)))
         (every (lambda (lib)
                  (eql 0 (nth-value 2 (uiop:run-program
                                       (list "codesign" "--force" "-s" "-" (uiop:native-namestring lib))
                                       :ignore-error-status t :output nil :error-output nil))))
                (list libb liba)))))

(defun %carry-pair-then-load (&key (relink t) (stamp t))
  "Carry the fixture pair into a bundle directory, delete the directory they were built in, and
load the carried libfixa.dylib in a fresh image, calling into it. RELINK NIL and STAMP NIL are
the controls. Returns (values LOAD-OUTPUT LOAD-CODE REPORT OTOOL-OF-CARRIED-A CODESIGN-CODE
INSTALL-NAME-OF-CARRIED-A), or NIL when the pair could not be compiled."
  (%load-carry-natives)
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/" tree)))
         (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
         (report (make-string-output-stream)))
    (unwind-protect
         (when (%dylib-pair app)
           (%write (merge-pathnames "LICENSE" app) "test license")
           (progv (list (find-symbol "*RELINK*" "OURANOS-CARRY") (find-symbol "*STAMP*" "OURANOS-CARRY"))
               (list relink stamp)
             (funcall (%carry-fn "CARRY-DECLARED-LIBRARIES")
                      (list (merge-pathnames "libfixb.dylib" app) (merge-pathnames "libfixa.dylib" app))
                      bundle :report report))
           (aion/fs:delete-tree app)
           (let* ((carried-a (uiop:native-namestring (merge-pathnames "libfixa.dylib" bundle)))
                  (otool (uiop:run-program (list "otool" "-L" carried-a) :output :string :ignore-error-status t))
                  (install-name (second (uiop:split-string
                                         (string-trim '(#\Newline)
                                                      (uiop:run-program (list "otool" "-D" carried-a)
                                                                        :output :string :ignore-error-status t))
                                         :separator '(#\Newline))))
                  (sign-code (nth-value 2 (uiop:run-program (list "codesign" "--verify" "--strict" carried-a)
                                                            :ignore-error-status t :output nil :error-output nil)))
                  (out (make-string-output-stream))
                  (code (nth-value 2 (uiop:run-program
                                      (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                            "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                                            "--eval" "(require :asdf)"
                                            "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
                                            "--eval" "(asdf:load-system :cffi)"
                                            "--eval" (format nil "(cffi:load-foreign-library ~S)" carried-a)
                                            "--eval" "(format t \"~&FIXA ~A~%\" (cffi:foreign-funcall \"fixa\" :int))")
                                      :output out :error-output out :ignore-error-status t))))
             (values (get-output-stream-string out) code (get-output-stream-string report) otool sign-code
                     install-name)))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(defun %relink-skip-reason ()
  (cond ((not (uiop:os-macosx-p)) "macOS only: install names are a Mach-O property")
        ((not (ignore-errors (eql 0 (nth-value 2 (uiop:run-program '("cc" "--version") :ignore-error-status t
                                                                    :output nil :error-output nil)))))
         "no C compiler (cc) to build the fixture dylibs")))

(test carried-dylibs-that-link-each-other-load-without-their-build-directory
  "#78 on macOS: A needs B by B's absolute install name. After carrying both, A's load command
names @loader_path/libfixb.dylib, A is re-signed, and A loads from the bundle and calls into B
with the directory they were built in gone."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (multiple-value-bind (out code report otool sign-code) (%carry-pair-then-load)
          (is (search "FIXA 43" (or out "")) "the carried library did not load or call B (exit ~A):~%~A" code out)
          (is (search "@loader_path/libfixb.dylib" (or otool "")) "A still names B by path:~%~A" otool)
          (is (eql 0 sign-code) "the relinked A does not verify: codesign --verify --strict exited ~A" sign-code)
          (is (search "now names @loader_path/libfixb.dylib" (or report "")) "the build did not report the relink:~%~A" report)))))

(test a-carried-dylib-with-an-absolute-install-name-is-stamped-relative
  "#957: the fixture's dylibs are built with their absolute build path as their install name, as
the tree's libuv and Homebrew's libraries are. The carried copy of A has the install name
@executable_path/libfixa.dylib, verifies, and still loads and calls B. Control: with the stamp
off, the carried copy keeps the build path."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (progn
          (multiple-value-bind (out code report otool sign-code install-name) (%carry-pair-then-load)
            (declare (ignore otool))
            (is (equal "@executable_path/libfixa.dylib" install-name) "install name: ~S" install-name)
            (is (eql 0 sign-code) "the stamped A does not verify: codesign --verify --strict exited ~A"
                sign-code)
            (is (search "FIXA 43" (or out "")) "the stamped A did not load (exit ~A):~%~A" code out)
            (is (search "install name is now @executable_path/libfixa.dylib" (or report ""))
                "the build did not report the stamp:~%~A" report))
          (multiple-value-bind (out code report otool sign-code install-name)
              (%carry-pair-then-load :stamp nil)
            (declare (ignore out code report otool sign-code))
            (is (and install-name (char= #\/ (char install-name 0))
                     (search "libfixa.dylib" install-name))
                "control: without the stamp the install name is the build path, got ~S" install-name))))))

(defun %with-otool-stub (function)
  "Call FUNCTION with PATH starting at a fresh directory whose `otool' exits 1 and prints
nothing, as /usr/bin/otool does on a Mac without the Command Line Tools."
  (let* ((tree (%fresh-tree))
         (bin (ensure-directories-exist (merge-pathnames "bin/" tree)))
         (stub (merge-pathnames "otool" bin))
         (path (uiop:getenv "PATH")))
    (%write stub (format nil "#!/bin/sh~%exit 1~%"))
    (uiop:run-program (list "chmod" "+x" (uiop:native-namestring stub)))
    (setf (uiop:getenv "PATH") (concatenate 'string (uiop:native-namestring bin) ":" path))
    (unwind-protect (funcall function)
      (setf (uiop:getenv "PATH") path)
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(defun %refusal-of (function &rest args)
  "The CARRY-REFUSED that FUNCTION signals on ARGS, or NIL when it returns."
  (handler-case (progn (apply function args) nil)
    (error (e) (and (typep e (find-symbol "CARRY-REFUSED" "OURANOS-CARRY")) e))))

(test a-mach-o-that-otool-cannot-read-is-refused-not-skipped
  "#958's review: when otool exits non-zero on a Mach-O, the stamp and the relink signal
CARRY-REFUSED instead of treating the file as having nothing to change. Controls: under the same
stub, a file that is not a Mach-O is skipped without an error; under the real otool, the same
dylib is stamped."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (dir (ensure-directories-exist (merge-pathnames "lib/" tree)))
               (stamp (%carry-fn "STAMP-INSTALL-NAME"))
               (dependencies (fdefinition (find-symbol "%MACHO-DEPENDENCIES" "OURANOS-CARRY")))
               (quiet (make-broadcast-stream)))
          (unwind-protect
               (if (not (%dylib-pair dir))
                   (fail "the fixture dylibs were not built")
                   (let ((dylib (merge-pathnames "libfixa.dylib" dir))
                         (text (%write (merge-pathnames "notes.txt" dir) "not a library")))
                     (%with-otool-stub
                      (lambda ()
                        (let ((refused (%refusal-of stamp dylib :report quiet)))
                          (is (not (null refused)) "the stamp did not refuse a dylib otool could not read")
                          (is (search "otool -D exited 1" (princ-to-string refused)) "~A" refused))
                        (is (not (null (%refusal-of dependencies dylib)))
                            "the relink's reading of load commands did not refuse")
                        (is (null (%refusal-of stamp text :report quiet))
                            "control: a file that is not a Mach-O is skipped without an error")))
                     (is (equal "@executable_path/libfixa.dylib" (funcall stamp dylib :report quiet))
                         "control: the real otool reads it and the stamp runs")))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))

;;; The stamp and the carry steps (#958's review). build-desktop-app.lisp carries in three steps,
;;; and each relinks only its own files, so a library one step carried that needs a library
;;; another step carried and stamped was left naming the build path. RELINK-BUNDLE runs after
;;; all three.

(defun %load-carried (file)
  "Load FILE, a carried libfixa.dylib, in a fresh image and call fixa. Returns what the image
printed."
  (let ((out (make-string-output-stream)))
    (uiop:run-program
     (list (uiop:native-namestring sb-ext:*runtime-pathname*)
           "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
           "--eval" "(require :asdf)"
           "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
           "--eval" "(asdf:load-system :cffi)"
           "--eval" (format nil "(cffi:load-foreign-library ~S)" (uiop:native-namestring file))
           "--eval" "(format t \"~&FIXA ~A~%\" (cffi:foreign-funcall \"fixa\" :int))")
     :output out :error-output out :ignore-error-status t)
    (get-output-stream-string out)))

(test a-library-carried-by-another-step-is-relinked-after-every-step
  "#958's review: B is carried and stamped by one step, as the runtime step carries libzstd, and
A, which needs B by B's build path, is carried by CARRY-DECLARED-LIBRARIES on its own, as a
--carry libarchive is. With the build directory gone, A does not load until RELINK-BUNDLE has
run, and then it loads and calls B. The load before RELINK-BUNDLE is the control."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (app (ensure-directories-exist (merge-pathnames "app/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (quiet (make-broadcast-stream))
               (report (make-string-output-stream)))
          (%load-carry-natives)
          (unwind-protect
               (if (not (%dylib-pair app))
                   (fail "the fixture dylibs were not built")
                   (let ((carried-a (merge-pathnames "libfixa.dylib" bundle))
                         (carried-b (merge-pathnames "libfixb.dylib" bundle)))
                     (%write (merge-pathnames "LICENSE" app) "test license")
                     (uiop:copy-file (merge-pathnames "libfixb.dylib" app) carried-b)
                     (is (equal "@executable_path/libfixb.dylib"
                                (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-b :report quiet))
                         "B was not stamped")
                     (funcall (%carry-fn "CARRY-DECLARED-LIBRARIES")
                              (list (merge-pathnames "libfixa.dylib" app)) bundle :report quiet)
                     (aion/fs:delete-tree app)
                     (let ((out (%load-carried carried-a)))
                       (is (search "Library not loaded" out)
                           "control: A loaded before RELINK-BUNDLE, so this cannot show it is needed:~%~A"
                           out))
                     (let ((names (funcall (%carry-fn "RELINK-BUNDLE") bundle :report report)))
                       (is (equal '("libfixa.dylib" "libfixb.dylib") (sort (copy-list names) #'string<))
                           "RELINK-BUNDLE read ~S" names))
                     (is (search "now names @loader_path/libfixb.dylib" (get-output-stream-string report))
                         "the relink was not reported")
                     (is (eql 0 (nth-value 2 (uiop:run-program
                                              (list "codesign" "--verify" "--strict"
                                                    (uiop:native-namestring carried-a))
                                              :ignore-error-status t :output nil :error-output nil)))
                         "the relinked A does not verify")
                     (let ((out (%load-carried carried-a)))
                       (is (search "FIXA 43" out) "A did not load after RELINK-BUNDLE:~%~A" out))))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))

(test a-library-carried-under-another-file-name-is-relinked-by-its-install-name
  "#1130: B is carried by one step under the file name libfixb.1.dylib, as the runtime step names
libzstd.1.dylib from its symbolic link, while A records B as .../app/libfixb.dylib, its build
path. Matching by file name finds nothing. STAMP-INSTALL-NAME records B's install name before
it changes it, and RELINK-BUNDLE uses that record, so A is pointed at libfixb.1.dylib, and loads
and calls B with the build directory gone. The control is RELINK-BUNDLE with the record empty,
which is what it read before #1130: A still names the build path and does not load."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (app (ensure-directories-exist (merge-pathnames "app/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (quiet (make-broadcast-stream)))
          (%load-carry-natives)
          (progv (list (find-symbol "*CARRIED-ORIGINS*" "OURANOS-CARRY")) (list '())
            (unwind-protect
                 (if (not (%dylib-pair app))
                     (fail "the fixture dylibs were not built")
                     (let ((carried-a (merge-pathnames "libfixa.dylib" bundle))
                           (carried-b (merge-pathnames "libfixb.1.dylib" bundle))
                           (build-b (uiop:native-namestring (merge-pathnames "libfixb.dylib" app))))
                       (%write (merge-pathnames "LICENSE" app) "test license")
                       (uiop:copy-file (merge-pathnames "libfixb.dylib" app) carried-b)
                       (is (equal "@executable_path/libfixb.1.dylib"
                                  (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-b
                                           :report quiet
                                           :source (merge-pathnames "libfixb.dylib" app)))
                           "B was not stamped")
                       (funcall (%carry-fn "CARRY-DECLARED-LIBRARIES")
                                (list (merge-pathnames "libfixa.dylib" app)) bundle :report quiet)
                       (aion/fs:delete-tree app)
                       (flet ((a-links ()
                                (uiop:run-program (list "otool" "-L" (uiop:native-namestring
                                                                      carried-a))
                                                  :output :string :ignore-error-status t)))
                         ;; The control: the same relink without the record.
                         (let ((report (make-string-output-stream)))
                           (progv (list (find-symbol "*CARRIED-ORIGINS*" "OURANOS-CARRY"))
                               (list '())
                             (funcall (%carry-fn "RELINK-BUNDLE") bundle :report report))
                           (is (search build-b (a-links))
                               "control: without the record A no longer names B's build path:~%~A"
                               (a-links))
                           (is (search "Library not loaded" (%load-carried carried-a))
                               "control: A loaded without the record"))
                         (let ((report (make-string-output-stream)))
                           (funcall (%carry-fn "RELINK-BUNDLE") bundle :report report)
                           (is (search (format nil "~A now names @loader_path/libfixb.1.dylib"
                                               build-b)
                                       (get-output-stream-string report))
                               "the relink was not reported")
                           (is (search "@loader_path/libfixb.1.dylib" (a-links))
                               "A does not name the carried B:~%~A" (a-links)))
                         (is (eql 0 (nth-value 2 (uiop:run-program
                                                  (list "codesign" "--verify" "--strict"
                                                        (uiop:native-namestring carried-a))
                                                  :ignore-error-status t :output nil
                                                  :error-output nil)))
                             "the relinked A does not verify")
                         (let ((out (%load-carried carried-a)))
                           (is (search "FIXA 43" out) "A did not load after RELINK-BUNDLE:~%~A"
                               out)))))
              (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))))

(test a-library-reached-through-a-symbolic-link-is-relinked-by-its-source-path
  "Review of #1137: as with Homebrew's /opt/homebrew/lib/libzstd.dylib, A names B by a symbolic
link, app/libfixb.dylib, while B's real file is app/libfixb.1.dylib and its install name is that
real file. So neither A's load command nor its file name matches the install name recorded for
the carried B. The build directory is kept while RELINK-BUNDLE runs, so the load command
resolves on this machine to the file B was copied from, and that is the match that points A at
libfixb.1.dylib. The control is RELINK-BUNDLE with the record empty: A still names the link."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (app (ensure-directories-exist (merge-pathnames "app/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (origins (find-symbol "*CARRIED-ORIGINS*" "OURANOS-CARRY"))
               (quiet (make-broadcast-stream)))
          (%load-carry-natives)
          (progv (list origins) (list '())
            (unwind-protect
                 (let* ((link (merge-pathnames "libfixb.dylib" app))
                        (real (merge-pathnames "libfixb.1.dylib" app))
                        (carried-a (merge-pathnames "libfixa.dylib" bundle))
                        (carried-b (merge-pathnames "libfixb.1.dylib" bundle)))
                   (flet ((tool-ok (&rest args)
                            (eql 0 (nth-value 2 (uiop:run-program
                                                 args :ignore-error-status t
                                                      :output nil :error-output nil))))
                          (a-links ()
                            (uiop:run-program (list "otool" "-L"
                                                    (uiop:native-namestring carried-a))
                                              :output :string :ignore-error-status t)))
                     (if (not (and (%dylib-pair app)
                                   (rename-file link real)
                                   (tool-ok "install_name_tool" "-id" (uiop:native-namestring real)
                                        (uiop:native-namestring real))
                                   (tool-ok "codesign" "--force" "-s" "-"
                                        (uiop:native-namestring real))
                                   (tool-ok "ln" "-s" "libfixb.1.dylib"
                                        (uiop:native-namestring link))))
                         (fail "the fixture dylibs were not built")
                         (progn
                           (%write (merge-pathnames "LICENSE" app) "test license")
                           (uiop:copy-file real carried-b)
                           (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-b
                                    :report quiet :source real)
                           (is (equal (uiop:native-namestring real)
                                      (second (first (symbol-value origins))))
                               "the recorded install name is not B's real file: ~S"
                               (symbol-value origins))
                           (funcall (%carry-fn "CARRY-DECLARED-LIBRARIES")
                                    (list (merge-pathnames "libfixa.dylib" app)) bundle
                                    :report quiet)
                           (is (search (uiop:native-namestring link) (a-links))
                               "A does not name B by the link, so this tests nothing:~%~A"
                               (a-links))
                           ;; The control: the same relink without the record.
                           (progv (list origins) (list '())
                             (funcall (%carry-fn "RELINK-BUNDLE") bundle :report quiet))
                           (is (search (uiop:native-namestring link) (a-links))
                               "control: without the record A no longer names the link:~%~A"
                               (a-links))
                           (let ((report (make-string-output-stream)))
                             (funcall (%carry-fn "RELINK-BUNDLE") bundle :report report)
                             (is (search (format nil "~A now names @loader_path/libfixb.1.dylib"
                                                 (uiop:native-namestring link))
                                         (get-output-stream-string report))
                                 "the relink was not reported"))
                           (is (search "@loader_path/libfixb.1.dylib" (a-links))
                               "A does not name the carried B:~%~A" (a-links))
                           (aion/fs:delete-tree app)
                           (let ((out (%load-carried carried-a)))
                             (is (search "FIXA 43" out)
                                 "A did not load after RELINK-BUNDLE:~%~A" out))))))
              (aion/fs:delete-tree tree :if-does-not-exist :ignore)))))))
(defun %with-failing-install-name-tool (function)
  "Call FUNCTION with PATH starting at a fresh directory whose `install_name_tool' prints the
error it gives when a header has no room for a longer name, and exits 1."
  (let* ((tree (%fresh-tree))
         (bin (ensure-directories-exist (merge-pathnames "bin/" tree)))
         (stub (merge-pathnames "install_name_tool" bin))
         (path (uiop:getenv "PATH")))
    (%write stub (format nil "#!/bin/sh~%echo 'error: install_name_tool: changing install names or rpaths can not be redone for: x (for architecture arm64) because larger updated load commands do not fit (the program must be relinked, and you may need to use -headerpad or -headerpad_max_install_names)' >&2~%exit 1~%"))
    (uiop:run-program (list "chmod" "+x" (uiop:native-namestring stub)))
    (setf (uiop:getenv "PATH") (concatenate 'string (uiop:native-namestring bin) ":" path))
    (unwind-protect (funcall function)
      (setf (uiop:getenv "PATH") path)
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test a-stamp-that-does-not-fit-warns-and-leaves-the-library-as-it-was
  "#958's review: when install_name_tool cannot set the new install name, STAMP-INSTALL-NAME
returns NIL with a warning on its report instead of refusing the carry, and the file keeps its
install name and a valid signature. Control: with the real install_name_tool the same file is
stamped."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (dir (ensure-directories-exist (merge-pathnames "lib/" tree)))
               (stamp (%carry-fn "STAMP-INSTALL-NAME"))
               (quiet (make-broadcast-stream)))
          (unwind-protect
               (if (not (%dylib-pair dir))
                   (fail "the fixture dylibs were not built")
                   (let* ((dylib (merge-pathnames "libfixa.dylib" dir))
                          (before (uiop:run-program (list "otool" "-D" (uiop:native-namestring dylib))
                                                    :output :string))
                          (report (make-string-output-stream)))
                     (%with-failing-install-name-tool
                      (lambda ()
                        (let ((refused nil) (result :unset))
                          (handler-case (setf result (funcall stamp dylib :report report))
                            (error (e) (setf refused e)))
                          (is (null refused) "the stamp refused: ~A" refused)
                          (is (null result) "the stamp returned ~S" result))))
                     (let ((said (get-output-stream-string report)))
                       (is (search "warning: install name left as" said) "no warning:~%~A" said)
                       (is (search "do not fit" said) "the warning does not give the reason:~%~A" said))
                     (is (equal before (uiop:run-program (list "otool" "-D" (uiop:native-namestring dylib))
                                                         :output :string))
                         "the install name changed")
                     (is (eql 0 (nth-value 2 (uiop:run-program
                                              (list "codesign" "--verify" "--strict"
                                                    (uiop:native-namestring dylib))
                                              :ignore-error-status t :output nil :error-output nil)))
                         "the signature is no longer valid")
                     (is (equal "@executable_path/libfixa.dylib" (funcall stamp dylib :report quiet))
                         "control: the real install_name_tool stamps it")))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))

(test carried-dylibs-that-link-each-other-fail-without-the-relink
  "The control: the same carry with the relink off. A still names B's build path, which has
been deleted, so A cannot load. Without this, the test above could pass on a machine where B
was found some other way."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (multiple-value-bind (out code) (%carry-pair-then-load :relink nil)
          (is (not (search "FIXA 43" (or out ""))) "A loaded without the relink:~%~A" out)
          (is (search "Library not loaded" (or out "")) "expected dyld's refusal (exit ~A):~%~A" code out)))))

;;; --- the bundle directory is read as a native file name ---------------------------------

(test the-runtime-directory-of-a-path-with-brackets-is-not-wild
  "OPEN-CARRIED-LIBRARIES opens each carried library from RUNTIME-DIRECTORY. A directory named
with [ or * in it is an ordinary directory, and must not become a wild pathname, or no carried
library would open and the app would exit 3. Since #899 every app that loads cl-sqlite carries
SQLite, so this applies to all of them. SBCL gives the running executable's path as a pathname
made by SB-EXT:NATIVE-PATHNAME, which is what this passes (measured on macOS with SBCL 2.6.9:
a runtime in a directory named `br [x]*' has a *RUNTIME-PATHNAME* that is not wild)."
  (let* ((exe (sb-ext:native-pathname
               (if (uiop:os-windows-p) "C:\\Apps\\My [Beta]*\\app.exe" "/opt/My [Beta]*/app")))
         (want (if (uiop:os-windows-p) "C:\\Apps\\My [Beta]*\\" "/opt/My [Beta]*/"))
         (dir (funcall (%carry-fn "RUNTIME-DIRECTORY") exe)))
    (is (equal (funcall (%carry-fn "RUNTIME-DIRECTORY") (sb-ext:native-namestring exe)) dir)
        "the path as a string gives another directory than as a pathname")
    (is (pathnamep sb-ext:*runtime-pathname*)
        "sb-ext:*runtime-pathname* is a ~S here, which RUNTIME-DIRECTORY was not written for"
        (type-of sb-ext:*runtime-pathname*))
    (is-false (wild-pathname-p dir) "~S parsed as a wild pathname" exe)
    (is (string= want (uiop:native-namestring dir)) "~S gave the directory ~S"
        exe (uiop:native-namestring dir))
    (is (string= (concatenate 'string want "libsqlite3.dylib")
                 (uiop:native-namestring (merge-pathnames "libsqlite3.dylib" dir)))
        "a carried file name merged into it is not the file beside the executable")))

;;; --- a carried path is read as a native file name (#1145) -------------------------------
;;;
;;; --carry and --carry-license paths come from the command line as the operating system's
;;; names for the files. Each test makes its files from native strings that are never parsed
;;; as Lisp namestrings, gives those strings to CARRY-DECLARED-LIBRARIES, and checks the
;;; bundle by native name, so a fixture cannot pass by going through the same parsing.

(defun %native-sep () (if (uiop:os-windows-p) "\\" "/"))

(defun %native-file (tree &rest parts)
  "Make the file PARTS (folder names, then a file name) under the directory TREE, each part
joined as a native string, and return the file's native name."
  (let ((native (concatenate 'string (string-right-trim "/\\" (uiop:native-namestring tree))
                             (format nil (concatenate 'string "~{" (%native-sep) "~A~}") parts))))
    (%write (uiop:parse-native-namestring native) "x")
    native))

(defun %native-in-bundle-p (bundle &rest parts)
  "Whether the file PARTS, joined as a native string under BUNDLE, exists."
  (uiop:file-exists-p
   (uiop:parse-native-namestring
    (concatenate 'string (string-right-trim "/\\" (uiop:native-namestring bundle))
                 (format nil (concatenate 'string "~{" (%native-sep) "~A~}") parts)))))

(defparameter +odd-folder-names+
  (list "lib [x]" #-win32 "a\\b")
  "Folder names a Lisp namestring reads differently from the native name: brackets, which it
reads as a wildcard, and on Linux and macOS a backslash, which it reads as an escape. Windows
allows neither * nor ? nor a backslash in a name.")

(test a-carry-path-in-a-folder-named-with-brackets-is-carried
  "#1145: CARRY-DECLARED-LIBRARIES gave each --carry path to PROBE-FILE, which parses it as a
Lisp namestring, so a library in a folder named lib [x] stopped the build with a wild-pathname
file error. The library and the LICENSE beside it must be carried."
  (dolist (folder +odd-folder-names+)
    (let* ((tree (%fresh-tree))
           (lib (%native-file tree folder "thing.dll")))
      (%native-file tree folder "LICENSE")
      (multiple-value-bind (e bundle) (%carry-refusal (list lib))
        (is (null e) "~S was refused: ~A" lib e)
        (is-true (%native-in-bundle-p bundle "thing.dll") "~S was not copied into the bundle" lib)
        (is-true (%native-in-bundle-p bundle "LICENSES" "thing-LICENSE")
                 "the LICENSE beside ~S was not carried" lib)))))

(test a-carry-license-in-a-folder-named-with-brackets-is-carried
  "#1145: a --carry-license path went through PROBE-FILE the same way as a --carry path."
  (dolist (folder +odd-folder-names+)
    (let* ((tree (%fresh-tree))
           (lib (%native-file tree "dll" "sqlite3.dll"))
           (note (%native-file tree folder "PUBLIC-DOMAIN.txt")))
      (multiple-value-bind (e bundle) (%carry-refusal (list (list lib note)))
        (is (null e) "the license ~S was refused: ~A" note e)
        (is-true (%native-in-bundle-p bundle "LICENSES" "sqlite3-PUBLIC-DOMAIN.txt")
                 "the license ~S was not carried" note)))))

(test a-carried-file-whose-name-has-brackets-keeps-its-name
  "#1145: the bundle's copy was named by merging the file name into the bundle directory, which
parses it as a Lisp namestring, so a library named thing[1].dll gave a wild pathname. The copy
must have the library's own name."
  (let* ((tree (%fresh-tree))
         (lib (%native-file tree "dll" "thing[1].dll")))
    (%native-file tree "dll" "LICENSE")
    (multiple-value-bind (e bundle) (%carry-refusal (list lib))
      (is (null e) "~S was refused: ~A" lib e)
      (is-true (%native-in-bundle-p bundle "thing[1].dll") "~S was not copied as thing[1].dll" lib))))

;;; --- check-install-names.sh, check 1b of verify-bundle-macos.sh (#957, #1131) -------------------
;;;
;;; The check read otool's second line with `head -n 2 | tail -n 1'. For a file with no install
;;; name otool prints only its header, the file's path and a colon, and that pipeline returned
;;; the header, which starts with the bundle directory and so was reported as ok. The check is
;;; now a script of its own, scripts/check-install-names.sh, so this test runs it on real dylibs
;;; without building or launching an app. A library with no install name is compiled with
;;; `cc -bundle', which writes a Mach-O file with no LC_ID_DYLIB, and named .dylib; once for
;;; this machine, and once universal (x86_64 and arm64), for which otool prints a header per
;;; architecture and no install name.

(defun %install-names-fixture (dir &key no-id)
  "Compile into DIR dylibs whose install names are inside DIR, relative, and an absolute path
outside DIR; with NO-ID, also noid.dylib and the universal noidfat.dylib, which have no install
name. Returns true when every compile succeeded."
  (let ((src (%write (merge-pathnames "f.c" dir) "int f(void) { return 1; }")))
    (flet ((cc (&rest args)
             (eql 0 (nth-value 2 (uiop:run-program (append (list "cc") args
                                                           (list (uiop:native-namestring src)))
                                                   :ignore-error-status t
                                                   :output nil :error-output nil))))
           (lib (name) (uiop:native-namestring (merge-pathnames name dir))))
      (and (cc "-dynamiclib" "-install_name" (lib "libinside.dylib") "-o" (lib "libinside.dylib"))
           (cc "-dynamiclib" "-install_name" "@executable_path/librel.dylib"
               "-o" (lib "librel.dylib"))
           (cc "-dynamiclib" "-install_name" "/opt/elsewhere/libabs.dylib"
               "-o" (lib "libabs.dylib"))
           (or (not no-id)
               (and (cc "-bundle" "-o" (lib "noid.dylib"))
                    (cc "-arch" "x86_64" "-arch" "arm64" "-bundle" "-o" (lib "noidfat.dylib"))))))))

(defun %check-install-names (&rest args)
  "Run scripts/check-install-names.sh with ARGS. (values EXIT-CODE OUTPUT)."
  (multiple-value-bind (out err code)
      (uiop:run-program (list* "sh" (uiop:native-namestring
                                     (merge-pathnames "check-install-names.sh" *scripts*))
                               args)
                        :output :string :error-output :output :ignore-error-status t)
    (declare (ignore err))
    (values code out)))

(test a-dylib-with-no-install-name-fails-the-install-name-check
  "#1131: noid.dylib and the universal noidfat.dylib have no install name. The check exits 1 with
a FAIL line naming each, and does not report either as ok. The control is the same directory
without the two, which exits 0: the library inside the bundle and the relative one are ok, and
the absolute path outside the bundle is a WARN, which does not fail."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let ((dir (uiop:native-namestring (%fresh-tree)))
              (control (uiop:native-namestring (%fresh-tree))))
          (is-true (%install-names-fixture dir :no-id t) "the fixture dylibs did not compile")
          (multiple-value-bind (code out) (%check-install-names dir)
            (is (eql 1 code) "exit ~A, expected 1:~%~A" code out)
            (is (search "FAIL -- otool -D printed no install name for noid.dylib" out)
                "no FAIL line for noid.dylib:~%~A" out)
            (is (not (search "ok -- noid.dylib" out)) "noid.dylib was reported ok:~%~A" out)
            (is (search "FAIL -- otool -D printed no install name for noidfat.dylib" out)
                "no FAIL line for the universal noidfat.dylib:~%~A" out)
            (is (not (search "ok -- noidfat.dylib" out))
                "the universal noidfat.dylib was reported ok:~%~A" out))
          (is-true (%install-names-fixture control) "the control's dylibs did not compile")
          (multiple-value-bind (code out) (%check-install-names control)
            (is (eql 0 code) "control: exit ~A, expected 0:~%~A" code out)
            (is (search "ok -- libinside.dylib" out) "control: libinside.dylib:~%~A" out)
            (is (search "ok -- librel.dylib: @executable_path/librel.dylib" out)
                "control: librel.dylib:~%~A" out)
            (is (search "WARN -- libabs.dylib has the install name /opt/elsewhere/libabs.dylib"
                        out)
                "control: libabs.dylib:~%~A" out)
            (is (not (search "FAIL" out)) "control: a FAIL line:~%~A" out))
          (is (eql 2 (%check-install-names)) "no directory is a bad command line")))))

;;; How RELINK-BUNDLE matches a load command to a carried library (#1143). It skipped every load
;;; command that starts with @, so one that names a carried library through @rpath was left as
;;; it was; and when nothing else matched it fell back to the file name alone, so a load command
;;; naming a library that was not carried was pointed at a carried one with the same name.

(defun %build-fixture-dylib (out source install-name &rest link-args)
  "Compile SOURCE, C text, into the dylib OUT with INSTALL-NAME and LINK-ARGS, and sign it with
codesign as %DYLIB-PAIR does. Returns true when both steps succeeded."
  (let ((c (make-pathname :type "c" :defaults out)))
    (%write c source)
    (flet ((ok (args)
             (eql 0 (nth-value 2 (uiop:run-program args :ignore-error-status t
                                                        :output nil :error-output nil)))))
      (and (ok (append (list "cc" "-dynamiclib" "-o" (uiop:native-namestring out)
                             (uiop:native-namestring c) "-install_name" install-name)
                       link-args))
           (ok (list "codesign" "--force" "-s" "-" (uiop:native-namestring out)))))))

(defun %otool-l (file)
  "What otool -L prints for FILE."
  (uiop:run-program (list "otool" "-L" (uiop:native-namestring file))
                    :output :string :ignore-error-status t))

(test a-carried-library-named-through-rpath-is-relinked
  "#1143: B's install name is @rpath/libfixb.dylib and A, linked with an rpath of the build
directory, names B as @rpath/libfixb.dylib. B is carried under the file name libfixb.1.dylib, as
the runtime step names libzstd.1.dylib. RELINK-BUNDLE points A at @loader_path/libfixb.1.dylib,
and A loads and calls B with the build directory gone. Before #1143 a load command starting
with @ was never changed, so A still looked for @rpath/libfixb.dylib, which the bundle has no
rpath to find."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (app (ensure-directories-exist (merge-pathnames "app/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (build-b (merge-pathnames "libfixb.dylib" app))
               (build-a (merge-pathnames "libfixa.dylib" app))
               (carried-a (merge-pathnames "libfixa.dylib" bundle))
               (carried-b (merge-pathnames "libfixb.1.dylib" bundle))
               (quiet (make-broadcast-stream)))
          (%load-carry-natives)
          (unwind-protect
               (if (not (and (%build-fixture-dylib build-b "int fixb(void) { return 42; }"
                                                    "@rpath/libfixb.dylib")
                             (%build-fixture-dylib
                              build-a "int fixb(void); int fixa(void) { return fixb() + 1; }"
                              (uiop:native-namestring build-a)
                              "-L" (uiop:native-namestring app) "-lfixb"
                              "-rpath" (uiop:native-namestring app))))
                   (fail "the fixture dylibs were not built")
                   (progn
                     (is (search "@rpath/libfixb.dylib" (%otool-l build-a))
                         "A does not name B through @rpath, so this tests nothing:~%~A"
                         (%otool-l build-a))
                     (uiop:copy-file build-b carried-b)
                     (uiop:copy-file build-a carried-a)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-b :report quiet
                                                                          :source build-b)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-a :report quiet
                                                                          :source build-a)
                     (let ((report (make-string-output-stream)))
                       (funcall (%carry-fn "RELINK-BUNDLE") bundle :report report)
                       (is (search "@rpath/libfixb.dylib now names @loader_path/libfixb.1.dylib"
                                   (get-output-stream-string report))
                           "the relink was not reported"))
                     (is (search "@loader_path/libfixb.1.dylib" (%otool-l carried-a))
                         "A does not name the carried B:~%~A" (%otool-l carried-a))
                     (is (eql 0 (nth-value 2 (uiop:run-program
                                              (list "codesign" "--verify" "--strict"
                                                    (uiop:native-namestring carried-a))
                                              :ignore-error-status t :output nil
                                              :error-output nil)))
                         "the relinked A does not verify")
                     (aion/fs:delete-tree app)
                     (let ((out (%load-carried carried-a)))
                       (is (search "FIXA 43" out) "A did not load after RELINK-BUNDLE:~%~A" out))))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))

(test a-library-that-only-shares-a-file-name-with-a-carried-one-is-not-relinked
  "#1143: two different libraries are both called libfixb.dylib. The one in a/ is carried; the
one in b/ is not, and A needs the one in b/. RELINK-BUNDLE leaves A's load command naming
b/libfixb.dylib, so A still calls b's fixb, which returns 7, and prints FIXA 8. Before #1143 a
load command that nothing else matched was matched by its file name alone, so A was pointed at
the carried a/libfixb.dylib and printed FIXA 43, calling a different library than it was built
against."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (dir-a (ensure-directories-exist (merge-pathnames "a/" tree)))
               (dir-b (ensure-directories-exist (merge-pathnames "b/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (a-b (merge-pathnames "libfixb.dylib" dir-a))
               (b-b (merge-pathnames "libfixb.dylib" dir-b))
               (build-a (merge-pathnames "libfixa.dylib" dir-b))
               (carried-a (merge-pathnames "libfixa.dylib" bundle))
               (quiet (make-broadcast-stream)))
          (%load-carry-natives)
          (unwind-protect
               (if (not (and (%build-fixture-dylib a-b "int fixb(void) { return 42; }"
                                                    (uiop:native-namestring a-b))
                             (%build-fixture-dylib b-b "int fixb(void) { return 7; }"
                                                    (uiop:native-namestring b-b))
                             (%build-fixture-dylib
                              build-a "int fixb(void); int fixa(void) { return fixb() + 1; }"
                              (uiop:native-namestring build-a)
                              "-L" (uiop:native-namestring dir-b) "-lfixb")))
                   (fail "the fixture dylibs were not built")
                   (progn
                     (is (search (uiop:native-namestring b-b) (%otool-l build-a))
                         "A does not name b/libfixb.dylib, so this tests nothing:~%~A"
                         (%otool-l build-a))
                     (uiop:copy-file a-b (merge-pathnames "libfixb.dylib" bundle))
                     (uiop:copy-file build-a carried-a)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME")
                              (merge-pathnames "libfixb.dylib" bundle) :report quiet)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-a :report quiet)
                     (let ((report (get-output-stream-string
                                    (let ((s (make-string-output-stream)))
                                      (funcall (%carry-fn "RELINK-BUNDLE") bundle :report s)
                                      s))))
                       (is (not (search "now names @loader_path/libfixb.dylib" report))
                           "A was relinked to the carried library of the same name:~%~A" report))
                     (is (search (uiop:native-namestring b-b) (%otool-l carried-a))
                         "A no longer names b/libfixb.dylib:~%~A" (%otool-l carried-a))
                     (let ((out (%load-carried carried-a)))
                       (is (search "FIXA 8" out)
                           "A did not call the library it was built against:~%~A" out))))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))

(test a-library-that-only-shares-an-rpath-install-name-with-a-carried-one-is-not-relinked
  "#1155's review: two different libraries both have the install name @rpath/libfixb.dylib. The
one in a/ (returns 42) is carried; A is built in b/ against the one in b/ (returns 7), with an
rpath of b/, so dyld loads b's. RELINK-BUNDLE resolves A's load command through A's source
location and rpaths to b/libfixb.dylib, which is not the carried file's source, and leaves it as
it is, with a line in the report. A still prints FIXA 8. Matching by the recorded install name
alone pointed A at the carried a/ copy, and A printed FIXA 43."
  (let ((why (%relink-skip-reason)))
    (if why
        (skip why)
        (let* ((tree (%fresh-tree))
               (dir-a (ensure-directories-exist (merge-pathnames "a/" tree)))
               (dir-b (ensure-directories-exist (merge-pathnames "b/" tree)))
               (bundle (ensure-directories-exist (merge-pathnames "bundle/" tree)))
               (a-b (merge-pathnames "libfixb.dylib" dir-a))
               (b-b (merge-pathnames "libfixb.dylib" dir-b))
               (build-a (merge-pathnames "libfixa.dylib" dir-b))
               (carried-b (merge-pathnames "libfixb.dylib" bundle))
               (carried-a (merge-pathnames "libfixa.dylib" bundle))
               (quiet (make-broadcast-stream)))
          (%load-carry-natives)
          (unwind-protect
               (if (not (and (%build-fixture-dylib a-b "int fixb(void) { return 42; }"
                                                    "@rpath/libfixb.dylib")
                             (%build-fixture-dylib b-b "int fixb(void) { return 7; }"
                                                    "@rpath/libfixb.dylib")
                             (%build-fixture-dylib
                              build-a "int fixb(void); int fixa(void) { return fixb() + 1; }"
                              (uiop:native-namestring build-a)
                              "-L" (uiop:native-namestring dir-b) "-lfixb"
                              "-rpath" (uiop:native-namestring dir-b))))
                   (fail "the fixture dylibs were not built")
                   (progn
                     (is (search "@rpath/libfixb.dylib" (%otool-l build-a))
                         "A does not name B through @rpath, so this tests nothing:~%~A"
                         (%otool-l build-a))
                     (uiop:copy-file a-b carried-b)
                     (uiop:copy-file build-a carried-a)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-b :report quiet :source a-b)
                     (funcall (%carry-fn "STAMP-INSTALL-NAME") carried-a :report quiet
                                                                          :source build-a)
                     (let ((report (get-output-stream-string
                                    (let ((s (make-string-output-stream)))
                                      (funcall (%carry-fn "RELINK-BUNDLE") bundle :report s)
                                      s))))
                       (is (not (search "now names @loader_path/libfixb.dylib" report))
                           "A was relinked to the carried library with the same install name:~%~A"
                           report)
                       (is (search "@rpath/libfixb.dylib left as it is" report)
                           "the load command left as it is was not reported:~%~A" report))
                     (is (search "@rpath/libfixb.dylib" (%otool-l carried-a))
                         "A no longer names @rpath/libfixb.dylib:~%~A" (%otool-l carried-a))
                     (let ((out (%load-carried carried-a)))
                       (is (search "FIXA 8" out)
                           "A did not call the library its rpath finds:~%~A" out))))
            (aion/fs:delete-tree tree :if-does-not-exist :ignore))))))
