;;;; app.lisp --- praxeon's SQLite retrieval, run inside a built desktop bundle (#899).
;;;;
;;;; This exists to be DUMPED and then RUN from the bundle, as aion/examples/uv-probe is:
;;;;
;;;;     sbcl --script scripts/build-sqlite.lisp
;;;;     sbcl --dynamic-space-size 4096 --script scripts/build-desktop-app.lisp \
;;;;          --system praxeon/examples/sqlite-probe --entry praxeon/examples/sqlite-probe:main \
;;;;          --name sqlite-probe --version 0.0.0
;;;;     dist/sqlite-probe-0.0.0-<os>-<arch>/sqlite-probe
;;;;
;;;; desktop-release.yml's sqlite-probe job does this on Linux, macOS and Windows, and builds
;;;; nothing it publishes.
;;;;
;;;; It opens no window, starts no hyperion-view and makes no network call. It opens a SQLite
;;;; file in a new temporary directory, syncs a fixed corpus, embeds it with a fixed word-hash
;;;; embedder defined here (no model), and runs RETRIEVE-SIMILAR and RETRIEVE-HYBRID. Then it
;;;; checks three things, and exits 0 only if all hold:
;;;;
;;;;   - each query returned the expected section ids, in the expected order;
;;;;   - the SQLite library the image calls (mnemosyne/sqlite-library, found from the address of
;;;;     sqlite3_open) is in the directory of the running executable, so it is the bundle's copy;
;;;;   - that library's version is the one sqlite.pin named when the probe was built.
;;;;
;;;; It prints `SQLITE-LIBRARY <version> <path>' as the test runner does (#129), so a log shows
;;;; which file was used even when a check fails.

(defpackage #:praxeon/examples/sqlite-probe
  (:use #:cl)
  (:local-nicknames (#:rt #:praxeon/retrieval)
                    (#:llm #:praxeon/llm)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:lib #:mnemosyne/sqlite-library))
  (:export #:main))

(in-package #:praxeon/examples/sqlite-probe)

(defun %pin-version ()
  "The version line of the tree's sqlite.pin."
  (with-open-file (in (asdf:system-relative-pathname "praxeon" "../sqlite.pin"))
    (loop for line = (read-line in nil nil)
          while line
          do (let ((tr (string-trim '(#\Space #\Tab #\Return) line)))
               (when (and (> (length tr) 8) (string= "version " tr :end2 8))
                 (return (string-trim '(#\Space #\Tab) (subseq tr 8))))))))

(defparameter *pinned-version* (%pin-version)
  "Read when the probe is loaded, on the build machine, and kept in the dumped image.")

;;; --- a fixed embedder -------------------------------------------------------------------
;;;
;;; Each word of four letters or more is hashed (FNV-1a over its character codes) into one of
;;; 255 dimensions, which count its occurrences; a 256th holds a constant so no vector is zero.
;;; Shorter words (a, is, the) are left out, so the vectors are about the content words. The
;;; same text always gives the same vector, on every machine.

(defparameter +width+ 256)

(defclass word-hash-embedder (llm:embedding-provider) ())

(defmethod llm:embedding-dimensions ((p word-hash-embedder)) +width+)
(defmethod llm:embedding-model-of ((p word-hash-embedder)) "sqlite-probe-word-hash")

(defun %words (text)
  (let ((words '()) (current '()))
    (flet ((flush ()
             (when current
               (push (coerce (nreverse current) 'string) words)
               (setf current '()))))
      (loop for c across text
            do (if (alphanumericp c) (push (char-downcase c) current) (flush)))
      (flush))
    (nreverse words)))

(defun %fnv-1a (word)
  (let ((h 2166136261))
    (loop for c across word
          do (setf h (logand #xFFFFFFFF (* (logxor h (char-code c)) 16777619))))
    h))

(defmethod llm:embed ((p word-hash-embedder) text)
  (let ((v (make-array +width+ :element-type 'double-float :initial-element 0d0)))
    (dolist (w (%words text))
      (when (>= (length w) 4)
        (incf (aref v (mod (%fnv-1a w) (1- +width+))))))
    (setf (aref v (1- +width+)) 0.1d0)
    v))

;;; --- the corpus and the expected answers ------------------------------------------------

(defparameter +sections+
  '(("garden" "g1" "Sow tomato seeds indoors six weeks before the last frost.")
    ("garden" "g2" "Harden off tomato seedlings outdoors for a week before planting.")
    ("garden" "g3" "Water beans at the roots in the morning, never the leaves.")
    ("garden" "g4" "Compost needs green kitchen scraps and brown dry leaves.")
    ("garden" "g5" "Prune roses in late winter, above an outward facing bud.")
    ("garden" "g6" "Mulch keeps soil moist and smothers weeds around beans.")
    ("refunds" "r1" "A refund is issued within thirty days of the request.")
    ("refunds" "r2" "Refund requests need the order number and the receipt.")
    ("refunds" "r3" "Shipping costs are not refunded unless the item arrived damaged.")
    ("refunds" "r4" "A payout is sent on the first business day of the month.")
    ("refunds" "r5" "Store credit can be chosen instead of a refund.")
    ("refunds" "r6" "Privacy: we never sell your data to anyone.")
    ("sky" "s1" "A telescope lens gathers more light than the human eye.")
    ("sky" "s2" "Jupiter shows four bright moons through a small telescope.")
    ("sky" "s3" "The Moon has no light of its own and reflects sunlight.")
    ("sky" "s4" "Meteor showers peak when Earth crosses a comet's dust trail.")
    ("sky" "s5" "Dark skies far from city lights reveal the Milky Way.")
    ("sky" "s6" "Saturn's rings are ice and rock, visible in a telescope.")
    ("bread" "b1" "Knead the dough until it is smooth and springs back.")
    ("bread" "b2" "Let the dough rise in a warm place until doubled.")
    ("bread" "b3" "A sourdough starter is flour and water left to ferment.")
    ("bread" "b4" "Bake bread until the crust is brown and sounds hollow.")
    ("bread" "b5" "Salt slows yeast, so add it after the flour is mixed.")
    ("bread" "b6" "Cool bread on a rack so the crust stays crisp."))
  "(document-id section-id text) for each section.")

(defparameter +queries+
  '((:similar "telescope light" ("s1" "s3" "s6"))
    (:similar "sourdough flour water" ("b3" "b5" "g3"))
    (:hybrid "when is my refund issued" ("r1" "r5" "r2"))
    (:hybrid "dough rise warm" ("b2" "b1" "r1")))
  "(kind query expected-ids): the top three section ids, in order. Measured with SQLite 3.51.0
on macOS: in each, the first four results have four different distances (or fused scores), so
the order of the three does not depend on how ties are broken.")

;;; --- the probe --------------------------------------------------------------------------

(defun report (label value)
  (format t "~&~A: ~A~%" label value)
  (finish-output))

(defun %ids (result)
  (mapcar (lambda (p) (rt:provenance-section-id (rt:passage-provenance p)))
          (rt:retrieval-result-passages result)))

(defun subseq* (list n)
  (subseq list 0 (min n (length list))))

(defun %fresh-directory ()
  (let ((dir (merge-pathnames (format nil "sqlite-probe-~36R/" (random (expt 2 48) (make-random-state t)))
                              (uiop:temporary-directory))))
    (when (probe-file dir) (error "~A already exists" dir))
    (ensure-directories-exist dir)))

(defun %retrieval (file)
  "Run every query in +QUERIES+ on a fresh corpus in FILE. Returns the number that failed."
  (let ((c (conn:connect (be:make-sqlite (uiop:native-namestring file))))
        (failed 0))
    (unwind-protect
         (let* ((store (rt:make-chunk-store c :table "probe_chunks" :dimensions +width+
                                              :ensure t))
                (corpus (rt:make-corpus store "probe" :strategy :hybrid))
                (embedder (make-instance 'word-hash-embedder)))
           (rt:sync-corpus corpus
                           (loop for (doc id text) in +sections+
                                 collect (rt:make-section :id id :document-id doc :text text
                                                          :locale "en"
                                                          :locator (format nil "§~A" id))))
           (report "embedded" (rt:embed-pending corpus embedder))
           (loop for (kind query expected) in +queries+
                 for got = (subseq* (%ids (ecase kind
                                            (:similar (rt:retrieve-similar corpus embedder query
                                                                           :limit 3))
                                            (:hybrid (rt:retrieve-hybrid corpus embedder query
                                                                         :limit 3))))
                                    3)
                 do (report (format nil "~(~A~) ~S" kind query)
                            (format nil "~{~A~^ ~}~:[ -- expected ~{~A~^ ~}~;~*~]"
                                    got (equal got expected) expected))
                    (unless (equal got expected) (incf failed))))
      (conn:disconnect c))
    failed))

(defun %same-directory-p (a b)
  "Whether directories A and B are the same, compared as resolved paths, ignoring case on
Windows, whose file system does."
  (let ((a (uiop:native-namestring (truename a)))
        (b (uiop:native-namestring (truename b))))
    (if (uiop:os-windows-p) (string-equal a b) (string= a b))))

(defun probe ()
  "Every step prints, so a failure names itself in the log. Returns the number of failures."
  (let* ((loaded (lib:loaded-library))
         (path (getf loaded :path))
         (version (getf loaded :version))
         (failures 0))
    (report "SQLITE-LIBRARY" (lib:describe-loaded-library loaded))
    (report "pinned-version" *pinned-version*)
    (unless (equal version *pinned-version*)
      (report "FAIL" (format nil "the library is SQLite ~A, and the pin is ~A" version
                             *pinned-version*))
      (incf failures))
    ;; PATH is the operating system's file name, so it is parsed as one: read as a Lisp
    ;; namestring, a bundle directory named with [ or * would be a wild pathname.
    (let ((here (uiop:pathname-directory-pathname sb-ext:*runtime-pathname*))
          (file (and path (uiop:parse-native-namestring path))))
      (report "executable-directory" (uiop:native-namestring here))
      (unless (and file (probe-file file)
                   (%same-directory-p (uiop:pathname-directory-pathname (truename file)) here))
        (report "FAIL" "the library is not the copy beside the executable")
        (incf failures)))
    (let ((dir (%fresh-directory)))
      (unwind-protect (incf failures (%retrieval (merge-pathnames "probe.db" dir)))
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))
    failures))

(defun main ()
  (handler-case
      (let ((failures (probe)))
        (report "probe" (if (zerop failures) "PASS" (format nil "FAIL (~D)" failures)))
        (uiop:quit (if (zerop failures) 0 1)))
    (error (e)
      (format t "~&probe: FAIL~%~A~%" e)
      (finish-output)
      (uiop:quit 1))))
