;;;; built-from.lisp --- the BUILT-FROM stamp a vendored library's build writes (#977).
;;;;
;;;; A build script that compiles a library into vendor/<name>/ writes vendor/<name>/BUILT-FROM,
;;;; naming the version and the source tarball's sha256 it built from. A library already in
;;;; vendor/ is reused only when its stamp names the pin's current version and sha256. Without
;;;; it, "the library file exists" was taken as "the library is current": after a pin moved, a
;;;; checkout that still held the old build kept it, said "already built", and exited 0, and
;;;; bundles carried the old release (#977, libuv 1.52.1 after the pin moved to 1.53.0).
;;;;
;;;; One copy of the format, loaded by build-libuv.lisp, build-sqlite.lisp and carry-natives.lisp,
;;;; so the scripts that write a stamp and the code that reads it cannot disagree about it.

(defpackage #:ouranos-built-from
  (:use #:cl)
  (:export #:stamp-path #:stamp-text #:write-stamp #:stamp-matches-p #:stamp-state
           #:delete-stamp #:stamp-version #:build-decision #:pin-field #:stamp-refusal))

(in-package #:ouranos-built-from)

(defun stamp-path (vendor-dir)
  "The BUILT-FROM file in VENDOR-DIR, a library's directory under vendor/."
  (merge-pathnames "BUILT-FROM" (uiop:ensure-directory-pathname vendor-dir)))

(defun stamp-text (version sha256)
  "What a stamp holds: the version, then the tarball's sha256 in lower case, one per line."
  (format nil "version ~A~%sha256 ~A~%" version (string-downcase sha256)))

(defun write-stamp (vendor-dir version sha256)
  "Record that the library in VENDOR-DIR was built from VERSION, whose tarball has SHA256."
  (with-open-file (out (stamp-path vendor-dir) :direction :output :if-exists :supersede)
    (write-string (stamp-text version sha256) out)))

(defun stamp-state (vendor-dir version sha256)
  "Whether the library in VENDOR-DIR was built from VERSION with SHA256, as a keyword:
:CURRENT when its stamp names them; :STALE when it names something else; :MISSING when there is
no stamp, as for a build made before the stamp existed. Only :CURRENT may be reused."
  (let ((path (probe-file (stamp-path vendor-dir))))
    (cond ((null path) :missing)
          ((string= (uiop:read-file-string path) (stamp-text version sha256)) :current)
          (t :stale))))

(defun stamp-matches-p (vendor-dir version sha256)
  "Whether VENDOR-DIR's stamp names VERSION and SHA256."
  (eq :current (stamp-state vendor-dir version sha256)))

(defun delete-stamp (vendor-dir)
  "Remove VENDOR-DIR's stamp, if there is one. A build script calls this before it compiles, so
a build that fails after overwriting the library leaves no stamp saying it is current (#1001)."
  (let ((path (probe-file (stamp-path vendor-dir))))
    (when path (delete-file path))))

(defun stamp-version (vendor-dir)
  "The version VENDOR-DIR's stamp names, or NIL when there is no stamp or it names none."
  (let ((path (probe-file (stamp-path vendor-dir))))
    (when path
      (with-open-file (in path)
        (loop for line = (read-line in nil nil)
              while line
              when (and (> (length line) 8) (string= "version " line :end2 8))
                do (return (string-trim '(#\Space #\Tab #\Return) (subseq line 8))))))))

(defun build-decision (vendor-dir library version sha256 &key force)
  "What a build script does about the library file LIBRARY in VENDOR-DIR, for the pin's VERSION
and SHA256 (#1001): :REUSE when LIBRARY exists, FORCE is false and the stamp names the pin;
otherwise why it builds, :FORCED, :ABSENT (no library), :STALE (the stamp names another
release) or :MISSING (no stamp). The scripts act on this, so a test can call the decision on a
fresh tree without compiling anything."
  (cond (force :forced)
        ((not (probe-file library)) :absent)
        (t (let ((state (stamp-state vendor-dir version sha256)))
             (if (eq state :current) :reuse state)))))

(defun pin-field (pin name)
  "The value of NAME in the pin file PIN (`name value' lines, # comments), or NIL."
  (with-open-file (in pin :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              do (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) tr)))
                   (when (and sp (string= name (subseq tr 0 sp)))
                     (return (string-trim '(#\Space #\Tab) (subseq tr sp)))))))))

(defun stamp-refusal (vendor-dir pin command)
  "NIL when VENDOR-DIR's library was built from the release PIN names, otherwise a sentence
saying what its stamp says, what the pin says, and to run COMMAND. Used where a bundle is about
to carry a vendored library (#1001)."
  (let ((version (pin-field pin "version"))
        (sha (pin-field pin "sha256")))
    (ecase (if (and version sha) (stamp-state vendor-dir version sha) :missing)
      (:current nil)
      (:stale (format nil "~A was built from ~A, and ~A names ~A. Rebuild it:~%  ~A"
                      (namestring vendor-dir) (or (stamp-version vendor-dir) "another release")
                      (file-namestring pin) version command))
      (:missing (format nil "~A has no BUILT-FROM stamp, so which release it was built from is unknown, and ~A names ~A. Rebuild it:~%  ~A"
                        (namestring vendor-dir) (file-namestring pin) version command)))))
