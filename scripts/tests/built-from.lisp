;;;; built-from.lisp --- the BUILT-FROM stamp of a vendored library's build (#977).
;;;;
;;;; scripts/built-from.lisp holds the one format of vendor/<name>/BUILT-FROM, which
;;;; build-libuv.lisp and build-sqlite.lisp write and carry-natives.lisp reads. These tests load
;;;; it by path, as those scripts do, and use a fresh directory for each case.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "built-from.lisp" *scripts*)))

(test a-library-is-current-only-when-its-stamp-names-the-pin
  "#977: a library whose stamp names the pin's version and sha256 is :CURRENT, and only that one
may be reused. Without a stamp, as for a build made before the stamp existed, it is :MISSING;
with a stamp for another version or another sha256 it is :STALE. Before #977 build-libuv.lisp
reused any library that existed, so a 1.52.1 build stayed after the pin moved to 1.53.0."
  (let ((dir (%fresh-tree))
        (sha "CB0D6DD2128D5A95BD242C6CC982A24FE608FA93DA57B6B4EC763B0018C53E64"))
    (is (eq :missing (ouranos-built-from:stamp-state dir "1.53.0" sha)))
    (ouranos-built-from:write-stamp dir "1.52.1" sha)
    (is (eq :stale (ouranos-built-from:stamp-state dir "1.53.0" sha)) "another version")
    (ouranos-built-from:write-stamp dir "1.53.0" (substitute #\0 #\C sha))
    (is (eq :stale (ouranos-built-from:stamp-state dir "1.53.0" sha)) "another tarball")
    (ouranos-built-from:write-stamp dir "1.53.0" sha)
    (is (eq :current (ouranos-built-from:stamp-state dir "1.53.0" sha)))
    (is-true (ouranos-built-from:stamp-matches-p dir "1.53.0" (string-downcase sha))
             "the sha256 is compared in lower case, however the pin writes it")
    (is (string= (format nil "version 1.53.0~%sha256 ~A~%" (string-downcase sha))
                 (uiop:read-file-string (ouranos-built-from:stamp-path dir)))
        "the format build-sqlite.lisp wrote before the stamp was shared, so existing stamps stay valid")))

(test the-build-scripts-and-the-carry-read-the-one-stamp-format
  "#977: build-libuv.lisp, build-sqlite.lisp and carry-natives.lisp load built-from.lisp and keep
no copy of the format of their own, so the writers and the reader cannot disagree."
  (dolist (file '("build-libuv.lisp" "build-sqlite.lisp" "carry-natives.lisp"))
    (let ((text (uiop:read-file-string (merge-pathnames file *scripts*))))
      (is (search "\"built-from.lisp\"" text) "~A loads built-from.lisp" file)
      (is (null (search "version ~A~%sha256" text)) "~A has no copy of the format" file))))

(test a-build-script-reuses-a-library-only-when-its-stamp-names-the-pin
  "#1001: BUILD-DECISION is what build-libuv.lisp acts on. It reuses the library only when the
library exists, --force was not given and the stamp names the pin; otherwise it says why it
builds. The last case is the control: the same tree, stamped for the pin, is reused."
  (let* ((dir (%fresh-tree))
         (library (merge-pathnames "lib/libuv.so" dir))
         (sha "cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64"))
    (flet ((decide (&key force)
             (ouranos-built-from:build-decision dir library "1.53.0" sha :force force)))
      (ouranos-built-from:write-stamp dir "1.53.0" sha)
      (is (eq :absent (decide)) "a stamp without its library is not a build")
      (ensure-directories-exist library)
      (with-open-file (out library :direction :output) (write-string "x" out))
      (ouranos-built-from:delete-stamp dir)
      (is-false (probe-file (ouranos-built-from:stamp-path dir)) "DELETE-STAMP removes the stamp")
      (is (eq :missing (decide)) "a library from before the stamp is rebuilt")
      (ouranos-built-from:write-stamp dir "1.52.1" sha)
      (is (eq :stale (decide)) "a library from another release is rebuilt")
      (is (equal "1.52.1" (ouranos-built-from:stamp-version dir)))
      (ouranos-built-from:write-stamp dir "1.53.0" sha)
      (is (eq :forced (decide :force t)) "--force rebuilds a current library")
      (is (eq :reuse (decide)) "control: a library stamped for the pin is reused")
      (finishes (ouranos-built-from:delete-stamp (%fresh-tree)) "no stamp to delete is not an error"))))

(test build-libuv-deletes-the-old-stamp-before-it-compiles
  "#1001: a compile that fails after overwriting the library must not leave the previous stamp
saying the library is current. build-libuv.lisp decides with BUILD-DECISION and deletes the
stamp before COMPILE-LIBRARY runs; the stamp is written again only after the build succeeds."
  (let* ((text (uiop:read-file-string (merge-pathnames "build-libuv.lisp" *scripts*)))
         (delete (search "(ouranos-built-from:delete-stamp" text))
         (compile (search "(compile-library srcdir)" text))
         (write (search "(ouranos-built-from:write-stamp" text)))
    (is (search "(ouranos-built-from:build-decision" text) "it decides with BUILD-DECISION")
    (is (and delete compile (< delete compile)) "the stamp is deleted before the compile")
    (is (and compile write (< compile write)) "and written after it")))

(test a-bundle-refuses-a-vendored-library-whose-stamp-does-not-name-the-pin
  "#1001: STAMP-REFUSAL is what tree-natives.lisp asks before it agrees to carry a library
build-libuv.lisp built. A missing or stale stamp gives a sentence naming both versions and the
command to run; a stamp for the pin gives NIL, which is the control."
  (let* ((tree (%fresh-tree))
         (vendor (merge-pathnames "vendor/libuv/" tree))
         (pin (merge-pathnames "libuv.pin" tree))
         (sha "cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64")
         (command "sbcl --script scripts/build-libuv.lisp"))
    (ensure-directories-exist vendor)
    (with-open-file (out pin :direction :output)
      (format out "# libuv~%version 1.53.0~%sha256 ~A~%" sha))
    (let ((missing (ouranos-built-from:stamp-refusal vendor pin command)))
      (is (and missing (search "no BUILT-FROM stamp" missing) (search "1.53.0" missing)
               (search command missing))
          "no stamp: ~S" missing))
    (ouranos-built-from:write-stamp vendor "1.52.1" sha)
    (let ((stale (ouranos-built-from:stamp-refusal vendor pin command)))
      (is (and stale (search "1.52.1" stale) (search "1.53.0" stale) (search command stale))
          "another release: ~S" stale))
    (ouranos-built-from:write-stamp vendor "1.53.0" sha)
    (is (null (ouranos-built-from:stamp-refusal vendor pin command))
        "control: a library stamped for the pin is carried")))
