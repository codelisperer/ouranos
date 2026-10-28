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
