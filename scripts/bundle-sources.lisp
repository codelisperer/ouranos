;;;; bundle-sources.lisp --- a library whose licence is not permissive travels with its source.
;;;;
;;;; ADR-0013's amendment of 2026-10-01 (#429): libgit2, which aion/libgit binds, is GPLv2 with
;;;; the libgit2 linking exception, and is the one such library a desktop bundle may carry. The
;;;; GPL requires that whoever distributes the binary also makes its source available, so a
;;;; bundle that carries libgit2 also carries:
;;;;   - SOURCES/<the pinned tarball>, whose sha256 must be the one the pin records;
;;;;   - LICENSES/libgit2-COPYING, the licence from that tarball.
;;;;
;;;; This file holds what both halves need, so they cannot disagree:
;;;;   - scripts/build-desktop-app.lisp puts the tarball there, and refuses to build a bundle
;;;;     whose tarball does not match the pin;
;;;;   - scripts/check-bundle-sources.lisp checks a built bundle, and the verify-bundle scripts
;;;;     for all three platforms run it.
;;;;
;;;; Any other library whose licence is not permissive needs its own decision by the maintainer,
;;;; recorded in ADR-0013, before it is added to *CARRIED-SOURCES*.

(defpackage #:ouranos-bundle-sources
  (:use #:cl)
  (:export #:*carried-sources* #:source-for-package #:carry-source #:check-bundle
           #:source-refused #:sha256-of))

(in-package #:ouranos-bundle-sources)

(defparameter *carried-sources*
  '((:package "libgit2"
     :pin "libgit2.pin"
     :tarball "libgit2-~A.tar.gz"
     :licence "COPYING"
     ;; How a bundle's copy of the library is recognised: what build-libgit2.lisp writes on
     ;; each platform, libgit2.so.1.9, libgit2.1.9.dylib and git2.dll.
     :library-prefixes ("libgit2." "git2.")))
  "The libraries a bundle may carry only with their source: each a plist naming its vendor/
package, its pin file at the tree's root, its tarball's name (with ~A for the pinned version)
under vendor/<package>/src/, the licence file it ships, and how its library file is named.")

(define-condition source-refused (error)
  ((reason :initarg :reason :reader source-refused-reason))
  (:report (lambda (c s) (format s "~A" (source-refused-reason c)))))

(defun source-for-package (name)
  "The *CARRIED-SOURCES* entry for the vendor/ package NAME, or NIL."
  (find name *carried-sources* :key (lambda (e) (getf e :package)) :test #'string=))

(defun %pin-field (root pin name)
  "The value of NAME in the pin file PIN at ROOT: lines are `name value', # comments."
  (with-open-file (in (merge-pathnames pin root) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil) while line
            for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
            when (and (plusp (length trimmed)) (char/= #\# (char trimmed 0))
                      (uiop:string-prefix-p (concatenate 'string name " ") trimmed))
              return (string-trim '(#\Space #\Tab) (subseq trimmed (length name)))))))

(defun %first-word (s) (subseq s 0 (or (position #\Space s) (length s))))

(defun sha256-of (file)
  "FILE's sha256 in lowercase hex, from sha256sum, shasum or certutil, as build-libgit2.lisp
computes it."
  (flet ((run (args) (uiop:run-program args :output :string :error-output nil)))
    (cond ((ignore-errors (run '("sha256sum" "--version")))
           (%first-word (run (list "sha256sum" (uiop:native-namestring file)))))
          ((ignore-errors (run '("shasum" "--version")))
           (%first-word (run (list "shasum" "-a" "256" (uiop:native-namestring file)))))
          ((uiop:os-windows-p)
           (let ((lines (uiop:split-string
                         (run (list "certutil" "-hashfile" (uiop:native-namestring file) "SHA256"))
                         :separator '(#\Newline))))
             (string-downcase (remove #\Return (remove #\Space (or (second lines) ""))))))
          (t (error 'source-refused :reason "no sha256 tool found (sha256sum, shasum or certutil)")))))

(defun %tarball-name (entry root)
  (let ((version (%pin-field root (getf entry :pin) "version")))
    (unless version
      (error 'source-refused :reason (format nil "~A records no version" (getf entry :pin))))
    (format nil (getf entry :tarball) version)))

(defun carry-source (entry root bundle)
  "Copy ENTRY's pinned tarball from vendor/ under ROOT into BUNDLE/SOURCES/, after checking its
sha256 against the pin. Signals SOURCE-REFUSED when the tarball is missing or does not match.
Returns the copy's pathname."
  (let* ((name (%tarball-name entry root))
         (want (%pin-field root (getf entry :pin) "sha256"))
         (from (merge-pathnames (format nil "vendor/~A/src/~A" (getf entry :package) name) root))
         (to (merge-pathnames (concatenate 'string "SOURCES/" name) bundle)))
    (unless (probe-file from)
      (error 'source-refused
             :reason (format nil "~A is missing; it is the source this bundle must carry with ~A. Run scripts/build-~A.lisp."
                             (uiop:native-namestring from) (getf entry :package) (getf entry :package))))
    (let ((got (sha256-of from)))
      (unless (string-equal got want)
        (error 'source-refused
               :reason (format nil "~A has sha256 ~A, and ~A pins ~A"
                               (uiop:native-namestring from) got (getf entry :pin) want))))
    (ensure-directories-exist to)
    (uiop:copy-file from to)
    to))

(defun %carries-p (entry bundle)
  "Whether BUNDLE's top level holds a file named like ENTRY's library."
  (some (lambda (file)
          (let ((name (file-namestring file)))
            (some (lambda (prefix) (uiop:string-prefix-p prefix name))
                  (getf entry :library-prefixes))))
        (uiop:directory-files bundle)))

(defun check-bundle (bundle root)
  "The problems with BUNDLE's carried sources, as a list of sentences; NIL when there are none.
For each library in *CARRIED-SOURCES* that BUNDLE carries, its tarball must be under SOURCES/
with the sha256 the pin under ROOT records, and its licence under LICENSES/."
  (let ((bundle (uiop:ensure-directory-pathname bundle))
        (problems '()))
    (dolist (entry *carried-sources* (nreverse problems))
      (when (%carries-p entry bundle)
        (let* ((package (getf entry :package))
               (name (handler-case (%tarball-name entry root)
                       (source-refused (e) (push (princ-to-string e) problems) nil)))
               (want (%pin-field root (getf entry :pin) "sha256"))
               (source (and name (merge-pathnames (concatenate 'string "SOURCES/" name) bundle)))
               (licence (merge-pathnames (format nil "LICENSES/~A-~A" package (getf entry :licence))
                                         bundle)))
          (cond ((null source))
                ((not (probe-file source))
                 (push (format nil "the bundle carries ~A but not its source, SOURCES/~A" package name)
                       problems))
                ((not (string-equal (sha256-of source) want))
                 (push (format nil "SOURCES/~A is not the pinned source: sha256 ~A, ~A pins ~A"
                               name (sha256-of source) (getf entry :pin) want)
                       problems)))
          (unless (probe-file licence)
            (push (format nil "the bundle carries ~A but not its licence, LICENSES/~A-~A"
                          package package (getf entry :licence))
                  problems)))))))
