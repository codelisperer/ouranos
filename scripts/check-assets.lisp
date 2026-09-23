;;;; check-assets.lisp --- prove the vendored browser assets match their pin.
;;;;
;;;; Run:  sbcl --script scripts/check-assets.lisp
;;;;
;;;; `hyperion/assets/vendor/ASSETS.pin` records a version, a sha256 and a source URL for
;;;; each vendored file. This checks the files ON DISK still hash to what the pin claims,
;;;; and that the fingerprints hard-coded in `hyperion/src/assets.lisp` are the head of
;;;; those same hashes. Exits non-zero on any mismatch.
;;;;
;;;; Its counterpart is the `hyperion/assets` test suite, which hashes the bytes compiled
;;;; INTO the image. Two different failures, and neither catches the other's: this finds a
;;;; tampered or half-updated source tree, that one finds a stale fasl.
;;;;
;;;; Why a pin at all: these bytes came off a CDN once and are now shipped inside every
;;;; image we build. An unpinned vendored file is indistinguishable from an edited one.
;;;; Same doctrine as `libuv.pin` and the appimagetool pin -- version plus checksum, or
;;;; it is not vendored, it is just copied.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (read-from-string "ql:quickload") :ironclad :silent t)

(defpackage #:check-assets (:use #:cl))
(in-package #:check-assets)

(defvar *root*
  ;; NOT `(make-pathname :directory (butlast ...))'. That form does not carry `:device'
  ;; through, and on Windows a device-less pathname is resolved against whatever drive the
  ;; process is standing on rather than the drive this script lives on (pre-publication issue 482). A checkout on
  ;; D: running against a fixture under %TEMP% on C: computed a root on D:, where nothing is,
  ;; and this script then raised FILE-DOES-NOT-EXIST reading an asset that was present all
  ;; along. `pathname-parent-directory-pathname' keeps the device, and it is already what
  ;; scripts/tree-root.lisp uses.
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defun vendor (name)
  (merge-pathnames (format nil "hyperion/assets/vendor/~a" name) *root*))

(defun words (line)
  (loop with start = 0
        for pos = (position #\Space line :start start)
        for w = (string-trim '(#\Space #\Tab #\Return) (subseq line start pos))
        unless (string= w "") collect w
        while pos do (setf start (1+ pos))))

(defun parse-pin ()
  "((name version sha256 filename) ...) from ASSETS.pin."
  (let ((entries '()) (current nil))
    (with-open-file (in (vendor "ASSETS.pin"))
      (loop for line = (read-line in nil)
            while line
            do (let ((w (words line)))
                 (cond ((or (null w) (eql #\# (char line 0))))
                       ((and (= 4 (length w)) (string= "sha256" (third w)))
                        (setf current (list (first w) (second w) (fourth w) nil))
                        (push current entries))
                       ((and (= 2 (length w)) (string= "file" (first w)) current)
                        (setf (fourth current) (second w)))))))
    (nreverse entries)))

(defun sha256-file (path)
  (string-downcase
   (with-output-to-string (s)
     (loop for b across (ironclad:digest-file :sha256 path)
           do (format s "~2,'0x" b)))))

(defun source-fingerprints ()
  "Fingerprint strings as written in hyperion/src/assets.lisp, in file order."
  (let ((text (with-open-file (in (merge-pathnames "hyperion/src/assets.lisp" *root*))
                (let ((s (make-string (file-length in))))
                  (subseq s 0 (read-sequence s in)))))
        (out '()) (start 0))
    (loop for pos = (search ":fingerprint \"" text :start2 start)
          while pos
          do (let* ((from (+ pos (length ":fingerprint \"")))
                    (to (position #\" text :start from)))
               (push (subseq text from to) out)
               (setf start to)))
    (nreverse out)))

(let ((failures 0)
      (pin (parse-pin)))
  (format t "~&Checking ~d vendored asset~:p against ASSETS.pin~%~%" (length pin))
  (when (null pin)
    (format t "  ERROR: ASSETS.pin recorded no entries -- parse failure or empty pin.~%")
    (sb-ext:exit :code 1))
  (dolist (e pin)
    (destructuring-bind (name version want file) e
      (cond
        ((null file)
         (incf failures)
         (format t "  ~12a FAIL  no `file` line in the pin~%" name))
        ((not (probe-file (vendor file)))
         (incf failures)
         (format t "  ~12a FAIL  ~a is missing~%" name file))
        (t
         (let ((got (sha256-file (vendor file))))
           (if (string= got want)
               (format t "  ~12a ok    ~a ~a  ~a~%" name version file (subseq got 0 8))
               (progn
                 (incf failures)
                 (format t "  ~12a FAIL  ~a~%                 pinned ~a~%                 actual ~a~%"
                         name file want got))))))))
  ;; The fingerprints in the source are the cache keys. A stale one serves current bytes
  ;; at an old URL, which is a cache-poisoning bug that nothing else here would catch.
  (format t "~%Checking URL fingerprints in hyperion/src/assets.lisp~%~%")
  (let ((fps (source-fingerprints)))
    (if (/= (length fps) (length pin))
        (progn
          (incf failures)
          (format t "  FAIL  ~d fingerprint~:p in the source, ~d asset~:p in the pin~%"
                  (length fps) (length pin)))
        (loop for e in pin
              for fp in fps
              do (let ((want (subseq (third e) 0 8)))
                   (if (string= fp want)
                       (format t "  ~12a ok    ~a~%" (first e) fp)
                       (progn
                         (incf failures)
                         (format t "  ~12a FAIL  source says ~a, pin says ~a~%"
                                 (first e) fp want)))))))
  (terpri)
  (if (zerop failures)
      (format t "PASS -- vendored assets match their pin.~%")
      (format t "FAIL -- ~d problem~:p.~%" failures))
  (sb-ext:exit :code (if (zerop failures) 0 1)))
