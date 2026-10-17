;;;; check-pins.lisp --- every pinned native declares where its advisories come from,
;;;; and when a human last looked.
;;;;
;;;;     sbcl --script scripts/check-pins.lisp            ; offline, deterministic
;;;;     sbcl --script scripts/check-pins.lisp --report   ; adds an age REPORT, still exit 0
;;;;
;;;; Exit 0 if every *.pin carries the required fields, 1 if any does not, 2 if it cannot
;;;; read a pin at all (so "I am misreading the format" is never reported as "the pin is
;;;; fine" -- the same reconciliation check-readme-counts.lisp makes against the gate log).
;;;;
;;;; WHY THIS EXISTS. libuv.pin already records a version, a sha256 and how to adopt a new
;;;; release. That is enough for a library whose cadence is sleepy. It is NOT enough for a
;;;; crypto library: when a TLS advisory lands, somebody has to NOTICE, and "somebody
;;;; remembers" is not a mechanism. So a pin must also say WHERE its advisories are
;;;; published and WHEN a human last checked them, and this makes both machine-checkable.
;;;;
;;;; WHAT IT DELIBERATELY DOES NOT DO: fail on age. A check that goes red because a date
;;;; passed turns an unrelated PR red on a calendar boundary, and a build that breaks for
;;;; reasons the author did not cause is a build people learn to ignore. Age is REPORTED,
;;;; loudly, and the failing condition is a missing FIELD -- which only ever changes when
;;;; somebody edits a pin, and is therefore attributable to the commit that caused it.
;;;;
;;;; The online question -- "is upstream ahead of us?" -- needs the network and belongs in a
;;;; scheduled job, not in a gate that must be reproducible offline. See
;;;; docs/versioning-and-pinning.md.

(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *identity-fields* '("version" "sha")
  "A pin must name WHAT we build in one of these. libuv.pin says `version 1.52.1';
coalton.pin says `sha 7915fad0'. Requiring one specific spelling would fail a pin that
already identifies itself perfectly well in the other.")

(defparameter *required*
  '("advisories" "reviewed")
  "Fields every pin must declare, on top of an identity field.

ADVISORIES is where a human goes to learn that what we build has a hole in it -- recorded in the pin because the answer is per-library and finding it again
under time pressure is exactly the wrong moment. REVIEWED is the date somebody last read
that page, which is the only field that distinguishes `no advisories affect us' from
`nobody has looked'. Those two states are indistinguishable without it, and one of them is
fine.

SHA256 and URL are NOT required here: coalton.pin names a git commit, which is its own
integrity check. Requiring them would fail a pin that is already stronger.")

(defun pin-files ()
  "Every *.pin file in the tree, outside .git. Before #735 this looked only at the repository
root, so hyperion/assets/vendor/ASSETS.pin and hyperion/src/vendor/PLURALS.pin were never
checked."
  (sort (remove-if (lambda (p) (search "/.git/" (namestring p)))
                   (directory (merge-pathnames "**/*.pin" *root*)))
        #'string< :key #'namestring))

(defun asset-line-p (line)
  "Is LINE an asset's first line in an ASSETS.pin-style file: `NAME VERSION sha256 HASH',
starting in the first column?"
  (and (plusp (length line))
       (not (member (char line 0) '(#\Space #\Tab #\#)))
       (let ((w (remove "" (uiop:split-string (string-right-trim '(#\Return) line)
                                              :separator '(#\Space #\Tab))
                        :test #'string=)))
         (and (= 4 (length w)) (string= "sha256" (third w)) w))))

(defun pin-blocks (path)
  "The pins PATH holds, as (label . fields). A file of `name value' fields is one pin. A file of
asset blocks, each starting with an ASSET-LINE-P line and continued by indented fields, is one
pin per asset, and each asset must carry the required fields itself (#735)."
  (let ((lines (with-open-file (in path :if-does-not-exist nil)
                 (unless in (error "cannot open ~A" (human-path:human-path path)))
                 (loop for line = (read-line in nil nil) while line collect line))))
    (if (notany #'asset-line-p lines)
        (list (cons (enough-namestring path *root*) (read-pin path)))
        (let ((blocks '()))
          (dolist (line lines (nreverse (mapcar (lambda (b) (cons (car b) (reverse (cdr b)))) blocks)))
            (let ((head (asset-line-p line))
                  (trimmed (string-trim '(#\Space #\Tab #\Return) line)))
              (cond (head
                     (push (list (format nil "~A ~A" (enough-namestring path *root*) (first head))
                                 (cons "version" (second head)))
                           blocks))
                    ((or (zerop (length trimmed)) (char= #\# (char trimmed 0)) (null blocks)))
                    ((member (char line 0) '(#\Space #\Tab))
                     (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) trimmed)))
                       (push (if sp
                                 (cons (subseq trimmed 0 sp) (string-trim '(#\Space #\Tab) (subseq trimmed sp)))
                                 (cons trimmed ""))
                             (cdr (first blocks))))))))))))

(defun read-pin (path)
  "PATH's `name value' lines as an alist. Blank lines and # comments ignored."
  (with-open-file (in path :if-does-not-exist nil)
    (unless in (error "cannot open ~A" (human-path:human-path path)))
    (loop for line = (read-line in nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          unless (or (zerop (length trimmed)) (char= #\# (char trimmed 0)))
            collect (let ((sp (position-if (lambda (c) (member c '(#\Space #\Tab))) trimmed)))
                      (if sp
                          (cons (subseq trimmed 0 sp)
                                (string-trim '(#\Space #\Tab) (subseq trimmed sp)))
                          (cons trimmed ""))))))

(defun days-since (iso)
  "Whole days from ISO (YYYY-MM-DD) to today, or NIL if it does not parse."
  (when (and (stringp iso) (= 10 (length iso)))
    (let ((y (parse-integer iso :start 0 :end 4 :junk-allowed t))
          (m (parse-integer iso :start 5 :end 7 :junk-allowed t))
          (d (parse-integer iso :start 8 :end 10 :junk-allowed t)))
      (when (and y m d)
        (floor (- (get-universal-time) (encode-universal-time 0 0 0 d m y 0))
               86400)))))

(defun main ()
  (let ((pins (pin-files))
        (bad 0)
        (report (member "--report" (uiop:command-line-arguments) :test #'string=)))
    (when (null pins)
      (format *error-output* "check-pins: no *.pin files found under ~A~%" (human-path:human-path *root*))
      (uiop:quit 2))
    (format t "~&Pins under ~A~%~%" (human-path:human-path *root*))
    (setf pins (loop for path in pins
                     append (handler-case (pin-blocks path)
                              (error (e)
                                (format *error-output* "check-pins: cannot read ~A: ~A~%"
                                        (enough-namestring path *root*) e)
                                (uiop:quit 2)))))
    (dolist (block pins)
      (let* ((name (car block))
             (fields (cdr block))
             (missing (append
                       (unless (some (lambda (f) (assoc f fields :test #'string=))
                                     *identity-fields*)
                         (list (format nil "one of ~{~A~^/~}" *identity-fields*)))
                       (remove-if (lambda (f) (assoc f fields :test #'string=)) *required*))))
        (cond
          (missing
           (incf bad)
           (format t "  FAIL  ~40A missing: ~{~A~^, ~}~%" name missing))
          (t
           (let* ((reviewed (cdr (assoc "reviewed" fields :test #'string=)))
                  (age (days-since reviewed)))
             (format t "  ok    ~40A at ~A, reviewed ~A~@[ (~D days ago)~]~%"
                     name
                     (or (cdr (assoc "version" fields :test #'string=))
                         (cdr (assoc "sha" fields :test #'string=)))
                     reviewed
                     (and report age))
             (when (and report age (> age 180))
               (format t "        ^ REVIEW IS ~D DAYS OLD -- read ~A~%"
                       age (cdr (assoc "advisories" fields :test #'string=)))))))))
    (terpri)
    (cond
      ((plusp bad)
       (format *error-output*
               "check-pins: ~D pin~:P missing required fields.~%Every pin declares `advisories <url>' and `reviewed <YYYY-MM-DD>'.~%See docs/versioning-and-pinning.md.~%" bad)
       (uiop:quit 1))
      (t
       (format t "All ~D pin~:P declare an advisory source and a review date.~%" (length pins))
       (uiop:quit 0)))))

(main)
