;;;; mbedtls-sources.lisp --- the set of sources we compile, and a check that notices it moving.
;;;;
;;;;   sbcl --script scripts/mbedtls-sources.lisp --record <unpacked-tree>
;;;;       print the manifest and the pin lines for a new version
;;;;
;;;;   sbcl --script scripts/mbedtls-sources.lisp <unpacked-tree>
;;;;       verify that tree against the committed mbedtls.sources; exit 1 on any difference
;;;;
;;;; WHY THIS EXISTS, and it is not the same reason build-libuv.lisp has a source list.
;;;;
;;;; libuv's build files NAME their sources, so `build-libuv.lisp` transcribes three explicit
;;;; lists and a version bump is checkable by diffing ours against upstream's. mbedTLS 4.x
;;;; does not name them: the crypto is a second project inside the tarball whose CMake says
;;;;
;;;;     file(GLOB src_crypto "${CMAKE_CURRENT_SOURCE_DIR}/*.c")
;;;;
;;;; A glob is trivial to reproduce -- we glob the same directories -- but it means THERE IS
;;;; NO UPSTREAM LIST TO DIFF AGAINST. The property we actually need is not "does our list
;;;; match theirs" but "DID THE SET OF SOURCE FILES CHANGE BETWEEN PINS", and that question
;;;; has to be asked of the two trees rather than of two lists.
;;;;
;;;; THE FAILURE THIS PREVENTS IS SILENT. `build-libuv.lisp`'s own header warns that a moved
;;;; or added source does not break the build -- it produces a library missing a file it
;;;; needed, or built without a feature it should have had. A glob makes that warning MORE
;;;; load-bearing, not less: with a named list, a file upstream added is a file our list
;;;; lacks and a human might notice. With a glob, a file upstream MOVED is silently dropped
;;;; and a file upstream ADDED is silently compiled in. Neither says anything.
;;;;
;;;; The evidence that this is real rather than theoretical, and it arrived by accident:
;;;; mbedTLS 4.1.1 has 437 files under tf-psa-crypto/ where 4.2.0 has 436. TWO ADJACENT
;;;; RELEASES, one file apart, nothing announcing it. Checking 4.1.1's manifest against the
;;;; 4.2.0 tree names it -- ecp_curves_new.c, an elliptic-curve source the build would
;;;; silently stop compiling.
;;;;
;;;; THE METHOD IS A SET COMPARISON, NOT A DIFF, and a reader arriving from build-libuv.lisp
;;;; needs to know that before looking for a list that does not exist. libuv's comment says
;;;; "verified against 1.52.1" and means "our transcription matches upstream's three named
;;;; lists at that version". Here there is no upstream list, so the manifest is compared
;;;; against a RE-GLOB of the pinned tree -- it verifies that the set we compile is the set
;;;; we recorded, which is a weaker claim than libuv's and the strongest one available.
;;;;
;;;; THREE FIELDS, THREE QUESTIONS, and none substitutes for another:
;;;;   mbedtls.pin sha256      did we get the BYTES we expected?
;;;;   sources-digest / this   is the SET we compile the set we transcribed?
;;;;   mbedtls.pin reviewed    has anybody asked whether those are still the bytes to WANT?
;;;; The digest sees a file appear or vanish. It does NOT see a file whose CONTENTS changed
;;;; -- that is the tarball hash's job, and this is why both exist.
;;;;
;;;; WHY A LIST AND NOT ONLY A DIGEST. A digest answers "did it change" and stops there. The
;;;; committed manifest answers "what changed", by name, which is the difference between a
;;;; failure somebody can act on and one they have to go and investigate. The digest in
;;;; mbedtls.pin ties the pin to the manifest, so a version bump cannot quietly keep an old
;;;; manifest.

(require :uiop)

;;; THE TREE IS THE CALLER'S, NOT THIS FILE'S (pre-publication issue 480) -- see scripts/tree-root.lisp. The
;;; manifest this writes is the record of which upstream sources a pinned mbedtls build
;;; uses, so writing it into the wrong checkout puts one tree's answer in another tree's
;;; provenance, which is the one thing a manifest exists not to do.
(defparameter *script* (or *load-truename* *load-pathname*))
(load (merge-pathnames "tree-root.lisp" (uiop:pathname-directory-pathname *script*)))

(defparameter *root* (tree-root:resolve-or-die *script* "mbedtls-sources"))

(defparameter *manifest* (merge-pathnames "mbedtls.sources" *root*))

(defparameter *source-dirs*
  '("library"
    "tf-psa-crypto/core"
    "tf-psa-crypto/drivers/builtin/src"
    "tf-psa-crypto/extras"
    "tf-psa-crypto/platform"
    "tf-psa-crypto/utilities")
  "The directories mbedTLS 4.x compiles into the library, and nothing else. 110 files.
VERIFIED AGAINST 4.1.1, BY LINKING -- see below, because reading was not enough.

Where each comes from: `library/` is mbedTLS's own TLS and X.509 (its Makefile's OBJS_X509
and OBJS_TLS; OBJS_CRYPTO delegates to the crypto project). The other five are the object
libraries `tf-psa-crypto/CMakeLists.txt:441-447` adds, each of which globs its own `*.c`:
core, drivers/builtin/src, extras, platform, utilities.

THE GLOBS ARE NOT THE LIST. The list is six object libraries; a glob is merely what three
of them happen to use to name their own files. `add_subdirectory` is the enumeration, and
those lines sit DIRECTLY ABOVE the globs -- so a reader who searches for `GLOB`, finds two,
and treats them as the answer stops one line short of the thing that would have corrected
them. That is not hypothetical: it is how the first version of this list was built.

THE FIRST VERSION HAD THREE OF THE SIX AND WAS WRONG BY 21 FILES. Nothing about that was detectable from the
globs themselves -- `extras/` holds pk.c, pkparse.c and md.c, which the TLS layer cannot
link without, and the omission surfaced only when a real compile failed on a missing
`pk_wrap.h`.

So the method that settles this list is not reading the build files. It is LINKING: a
complete shared library with no unresolved symbols is the evidence, and a source list that
merely looks right is not. `scripts/build-mbedtls.lisp` does that, and this list is what it
compiles.

NOT the whole crypto tree either. `find tf-psa-crypto -name '*.c'` returns 437 files in
4.1.1 and the library compiles 77 of them; the rest are tests, programs, examples, the
vendored `framework` submodule, `psasim`, and the pqcp drivers. Counting the directory
instead of reading the build files overstates it fivefold -- a mistake also already made on
#125. Both errors were about the same object, in opposite directions.")

(defun %sources-in (tree dir)
  (let* ((abs (merge-pathnames (concatenate 'string dir "/") tree))
         (files (directory (merge-pathnames "*.c" abs))))
    (mapcar (lambda (f) (format nil "~A/~A.c" dir (pathname-name f))) files)))

(defun collect (tree)
  "Every .c the library compiles, as sorted tree-relative paths."
  (sort (loop for dir in *source-dirs* append (%sources-in tree dir)) #'string<))

(defun manifest-text (files)
  (with-output-to-string (s)
    (dolist (f files) (write-line f s))))

(defun sha256-of (file)
  "Hex sha256 of FILE, by whatever the platform provides. Same approach as
build-libuv.lisp: an external tool rather than a crypto dependency in a --script."
  (flet ((which (p) (ignore-errors (uiop:run-program (list "sh" "-c" (format nil "command -v ~A" p))
                                                     :output '(:string :stripped t)
                                                     :ignore-error-status t)))
         (first-word (s) (subseq s 0 (or (position #\Space s) (length s)))))
    (cond
      ((plusp (length (or (which "sha256sum") "")))
       (first-word (uiop:run-program (list "sha256sum" (namestring file))
                                     :output '(:string :stripped t))))
      ((plusp (length (or (which "shasum") "")))
       (first-word (uiop:run-program (list "shasum" "-a" "256" (namestring file))
                                     :output '(:string :stripped t))))
      (t (error "No sha256 tool found (looked for sha256sum, shasum).")))))

(defun sha256-of-string (text)
  (uiop:with-temporary-file (:pathname p :stream s :direction :output)
    (write-string text s)
    (finish-output s)
    :close-stream
    (sha256-of p)))

(defun pin-field (name)
  "The value of NAME in mbedtls.pin, or NIL. Lines are `name value', # comments."
  (with-open-file (in (merge-pathnames "mbedtls.pin" *root*) :if-does-not-exist nil)
    (when in
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              do (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) tr)))
                   (when (and sp (string= name (subseq tr 0 sp)))
                     (return (string-trim '(#\Space #\Tab) (subseq tr sp)))))))))

(defun check-pin-agrees (found)
  "Assert mbedtls.pin's `sources-count'/`sources-digest' describe THIS manifest.

WHY THIS IS HERE AND NOT SOMEWHERE ELSE: it was nowhere. mbedtls.pin says the digest
`ties this pin to that manifest so a version bump cannot quietly keep an old one', and
until this function nothing ever compared the two -- not this script, not check-pins.lisp
(which only looks for a version/sha field), not verify-tree.lisp (which does not run
check-pins at all). An invariant nothing checks is not an invariant, and this one was
load-bearing in prose only.

The three fields answer three questions and none substitutes for another. This is the
second, and it was the only unenforced one:

  sha256          did we get the BYTES we expected?          -- build-mbedtls.lisp
  sources-digest  is the SET we compile the set we recorded? -- HERE
  reviewed        are those still the bytes to WANT?         -- a human, by date"
  (let ((count (pin-field "sources-count"))
        (digest (pin-field "sources-digest")))
    (unless (and count digest)
      (format *error-output*
              "mbedtls-sources: mbedtls.pin has no sources-count/sources-digest.~%")
      (uiop:quit 2))
    (let ((actual-count (length found))
          (actual-digest (sha256-of *manifest*)))
      (unless (eql actual-count (parse-integer count :junk-allowed t))
        (format *error-output* "mbedtls-sources: PIN DISAGREES WITH THE TREE.~%")
        (format *error-output* "  mbedtls.pin sources-count ~A, tree has ~D~%"
                count actual-count)
        (uiop:quit 1))
      (unless (string-equal actual-digest digest)
        (format *error-output* "mbedtls-sources: PIN DISAGREES WITH THE MANIFEST.~%")
        (format *error-output* "  mbedtls.pin sources-digest ~A~%" digest)
        (format *error-output* "  sha256(mbedtls.sources)    ~A~%" actual-digest)
        (format *error-output* "The pin was not re-recorded after the manifest changed.~%")
        (uiop:quit 1))
      (format t "  pin agrees: ~D sources, digest ~A~%"
              actual-count (subseq actual-digest 0 16)))))

(defun read-manifest ()
  (when (probe-file *manifest*)
    (with-open-file (in *manifest*)
      (loop for line = (read-line in nil nil)
            while line
            for tr = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length tr)) (char= #\# (char tr 0)))
              collect tr))))

(defun main ()
  (let* ((args (uiop:command-line-arguments))
         (record (member "--record" args :test #'string=))
         (tree-arg (find-if-not (lambda (a) (string= a "--record")) args)))
    (unless tree-arg
      (format *error-output* "usage: mbedtls-sources.lisp [--record] <unpacked-tree>~%")
      (uiop:quit 2))
    (let* ((tree (uiop:ensure-directory-pathname (truename tree-arg)))
           (found (collect tree)))
      (when (null found)
        ;; One directive per line, never a `~<newline>' continuation: on a CRLF checkout
        ;; the character after `~' is #\Return, which is an illegal directive and fails at
        ;; COMPILE time, not at the point of use (AGENTS.md).
        (format *error-output* "mbedtls-sources: no sources found under ~A.~%"
                (namestring tree))
        (format *error-output*
                "Expected the directories ~{~A~^, ~} -- is this an unpacked mbedTLS 4.x tree?~%"
                *source-dirs*)
        (uiop:quit 2))
      (cond
        (record
         (let ((text (manifest-text found)))
           (with-open-file (out *manifest* :direction :output :if-exists :supersede)
             (write-string text out))
           (format t "~&Wrote ~A (~D sources).~%~%Pin lines:~%~%"
                   (file-namestring *manifest*) (length found))
           (format t "sources-count  ~D~%sources-digest ~A~%"
                   (length found) (sha256-of *manifest*))))
        (t
         (let* ((expected (read-manifest)))
           (unless expected
             (format *error-output* "mbedtls-sources: ~A is missing or empty. Run --record.~%"
                     (namestring *manifest*))
             (uiop:quit 2))
           (let ((added (set-difference found expected :test #'string=))
                 (gone (set-difference expected found :test #'string=)))
             (cond
               ((and (null added) (null gone))
                (format t "~&ok: ~D sources, unchanged from ~A~%"
                        (length found) (file-namestring *manifest*))
                ;; The tree matches the manifest. That is only two of the three questions --
                ;; the pin must also still describe the manifest it was recorded against.
                (check-pin-agrees found)
                (uiop:quit 0))
               (t
                (format *error-output* "~&mbedtls-sources: THE SOURCE SET HAS CHANGED.~%~%")
                (dolist (f (sort gone #'string<))
                  (format *error-output* "  GONE   ~A~%" f))
                (dolist (f (sort added #'string<))
                  (format *error-output* "  NEW    ~A~%" f))
                (format *error-output* "~%A file that vanished is one the build silently stops compiling;~%")
                (format *error-output* "a file that appeared is one it silently starts. Read the release~%")
                (format *error-output* "notes, then re-record: --record <tree>, and bump mbedtls.pin.~%")
                (uiop:quit 1))))))))))

(main)
