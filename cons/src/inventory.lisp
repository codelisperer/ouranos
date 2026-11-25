;;;; inventory.lisp --- read an upstream.sexp and check it against the tree it describes (#716).
;;;;
;;;; This is the offline core of scripts/check-upstream.lisp, moved here so that a tree other
;;;; than Ouranos can be checked the same way, which is what `cons outdated' will do for an app
;;;; (#716, point 4). The rules are documented in scripts/check-upstream.lisp's header and in
;;;; upstream.sexp's; nothing here changes them.
;;;;
;;;; It needs only UIOP and the two helper files the script has always loaded,
;;;; scripts/human-path.lisp and scripts/pin-files.lisp. That is what lets the script keep
;;;; running under `sbcl --script' with no Quicklisp: it LOADs this file directly, as before.
;;;; The system cons/inventory lists the same three files, for code that loads it with ASDF.
;;;;
;;;; What the script used to do by quitting, this signals or returns, because a library must not
;;;; end the image: an unreadable upstream.sexp signals INVENTORY-UNREADABLE, and SELF-TEST
;;;; returns the number of failed cases. The online half, which needs aion/http-client and jzon,
;;;; is cons/outdated, so loading this pulls in neither.

(defpackage #:cons/inventory
  (:use #:cl)
  (:export #:*root* #:*program* #:*problems*
           #:inventory-unreadable
           #:offline-check #:self-test
           #:compare-pin #:retired-p #:today #:base #:write-markdown
           #:version-numbers #:version-shape #:version< #:newest #:stable-p
           #:up-to-space))
(in-package #:cons/inventory)

(defvar *root* nil
  "The directory whose upstream.sexp is checked, with its pins. The caller sets it: the script to
the tree it sits in, `cons outdated' to an app's directory.")

(defvar *program* "check-upstream"
  "The name the messages start with.")

(define-condition inventory-unreadable (error)
  ((message :initarg :message :reader inventory-unreadable-message))
  (:report (lambda (c s) (write-string (inventory-unreadable-message c) s)))
  (:documentation "upstream.sexp could not be read, or holds no entries. The script prints this
condition and exits 2."))

(defparameter *categories* '(:toolchain :quicklisp :native :asset :api :ci :container))

(defparameter *upstream-kinds*
  '(:github-release :github-commit :github-tag :npm :nuget :quicklisp-dist :docker :manual))

(defvar *problems* '()
  "Each finding, as a string, newest first.")

(defun problem (control &rest args)
  (push (apply #'format nil control args) *problems*))

;;; --- reading -------------------------------------------------------------------------------

(defun read-inventory (path)
  "Every form in PATH, read with *READ-EVAL* off. Signals when PATH cannot be read."
  (with-open-file (in path :external-format :utf-8)
    (with-standard-io-syntax
      ;; WITH-STANDARD-IO-SYNTAX reads into CL-USER, so NIL is NIL and :NAME is a keyword.
      (let ((*read-eval* nil))
        (loop for form = (read in nil in)
              until (eq form in)
              collect form)))))

(defun file-lines (relative)
  "The lines of the file RELATIVE to the tree, without carriage returns, or NIL when there is no
such file."
  (let ((path (merge-pathnames relative *root*)))
    (when (probe-file path)
      (with-open-file (in path :external-format :utf-8)
        (loop for line = (read-line in nil nil)
              while line
              collect (string-right-trim '(#\Return) line))))))

(defun words (line)
  (remove "" (uiop:split-string line :separator '(#\Space #\Tab)) :test #'string=))

(defun comment-line-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (or (zerop (length trimmed))
        (char= (char trimmed 0) #\#)
        (char= (char trimmed 0) #\;))))

(defun top-level-line-p (line)
  "True for a line that starts in the first column and is not a comment: a field or an asset
line of a .pin file, not a continuation."
  (and (plusp (length line))
       (not (member (char line 0) '(#\Space #\Tab)))
       (not (comment-line-p line))))

;;; --- places --------------------------------------------------------------------------------

(defun up-to-space (string)
  (subseq string 0 (or (position-if (lambda (c) (member c '(#\Space #\Tab))) string)
                       (length string))))

(defun place-values (place)
  "The values PLACE yields, one per occurrence, as (values list error-string). An error string
says why the place could not be read at all."
  (case (first place)
    (:env
     (destructuring-bind (file key) (rest place)
       (let ((lines (file-lines file))
             (prefix (format nil "~A=" key)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           when (and (>= (length line) (length prefix))
                                     (string= prefix line :end2 (length prefix)))
                             collect (string-trim " " (subseq line (length prefix))))
                     nil)))))
    (:field
     (destructuring-bind (file name) (rest place)
       (let ((lines (file-lines file)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           for w = (words line)
                           when (and (top-level-line-p line) (string= name (first w)) (second w))
                             collect (second w))
                     nil)))))
    (:text
     (destructuring-bind (file before after) (rest place)
       (let ((lines (file-lines file)))
         (if (null lines)
             (values nil (format nil "no file ~A" file))
             (values (loop for line in lines
                           append (loop with start = 0
                                        for at = (search before line :start2 start)
                                        while at
                                        collect (let* ((from (+ at (length before)))
                                                       (rest (subseq line from)))
                                                  (if after
                                                      (let ((end (search after rest)))
                                                        (if end (subseq rest 0 end) :unterminated))
                                                      (up-to-space rest)))
                                        do (setf start (1+ at))))
                     nil)))))
    (:concat
     (destructuring-bind (separator &rest parts) (rest place)
       (let ((values '()))
         (dolist (part parts)
           (multiple-value-bind (found error) (place-values part)
             (cond (error (return-from place-values (values nil error)))
                   ((null found) (return-from place-values (values nil nil)))
                   ((rest (remove-duplicates found :test #'equal))
                    (return-from place-values
                      (values nil (format nil "~S gives different values: ~{~A~^, ~}" part found))))
                   (t (push (first found) values)))))
         ;; Joined with WRITE-STRING, never by splicing SEPARATOR into a FORMAT control string:
         ;; upstream.sexp is data, and a ~/pkg:fn/ directive in it would call a function
         ;; (the hub's review of #737).
         (values (list (with-output-to-string (out)
                         (loop for (v . more) on (reverse values)
                               do (write-string v out)
                                  (when more (write-string separator out)))))
                 nil))))
    (t (values nil (format nil "unknown place ~S" place)))))

(defun place-file (place)
  (if (eq (first place) :concat)
      (place-file (third place))
      (second place)))

;;; --- entries -------------------------------------------------------------------------------

(defun date-p (x)
  (and (stringp x) (= 10 (length x))
       (every (lambda (i) (digit-char-p (char x i))) '(0 1 2 3 5 6 8 9))
       (char= #\- (char x 4)) (char= #\- (char x 7))))

(defun check-entry (entry)
  "Record every problem with ENTRY. Returns its value, or NIL when it has none."
  (let ((name (getf entry :name)))
    (unless (stringp name)
      (problem "an entry has no :name: ~S" entry)
      (return-from check-entry nil))
    (unless (member (getf entry :category) *categories*)
      (problem "~A: unknown :category ~S" name (getf entry :category)))
    (let ((upstream (getf entry :upstream)))
      (unless (and (consp upstream) (member (first upstream) *upstream-kinds*))
        (problem "~A: unknown :upstream ~S" name upstream))
      (when (and (consp upstream) (eq (first upstream) :manual))
        (let ((reviewed (getf entry :reviewed)))
          (unless (or (eq reviewed :never) (date-p reviewed))
            (problem "~A: a :manual upstream needs :reviewed YYYY-MM-DD or :never, not ~S" name reviewed)))))
    (let ((held (getf entry :held)))
      (when (and held (not (and (stringp (getf held :reason)) (integerp (getf held :issue)))))
        (problem "~A: :held needs a :reason string and an :issue number: ~S" name held)))
    (let ((retires (getf entry :retires :absent)))
      (unless (or (eq retires :absent) (date-p retires))
        (problem "~A: :retires needs a date YYYY-MM-DD, not ~S" name retires)))
    (let ((where (getf entry :where))
          (seen '()))
      (when (null where)
        (problem "~A: no :where" name))
      (dolist (place where)
        (multiple-value-bind (found error) (place-values place)
          (cond (error (problem "~A: ~A" name error))
                ((null found) (problem "~A: ~S no longer finds its pin" name place))
                ((member :unterminated found)
                 (problem "~A: ~S finds its start but not its end" name place))
                (t (dolist (v found) (pushnew v seen :test #'equal))))))
      (when (rest seen)
        (problem "~A: its places disagree: ~{~A~^, ~}" name (reverse seen)))
      (first seen))))

;;; --- coverage ------------------------------------------------------------------------------

(defun relative (path)
  (enough-namestring path *root*))

(defun pin-files ()
  "Every *.pin file in the tree that a checker reads, the same files check-pins.lisp reads; see
pin-files.lisp for what is left out (#808)."
  (pin-files:pin-files *root*))

(defun %key-up-to-version (value)
  "The part of VALUE before its version: up to and including its first `-' (ubuntu-24.04 =>
ubuntu-, windows-11-arm => windows-), or all of VALUE when it has none."
  (let ((dash (position #\- value)))
    (if dash (subseq value 0 (1+ dash)) value)))

(defun %suffix-p (suffix string)
  (and (> (length string) (length suffix))
       (string= suffix string :start2 (- (length string) (length suffix)))))

(defun %workflow-items (file)
  "The pins in the workflow FILE: each action it uses, each runner image named by `runs-on:' or a
matrix `os:', and each *_VERSION or *_COMMIT key of an env block. A value written as an
expression, such as ${{ matrix.os }}, names no image and is left out."
  (remove-duplicates
   (loop for line in (file-lines file)
         for w = (words line)
         unless (comment-line-p line)
           append (let ((items '()))
                    (let* ((at (search "uses: " line))
                           (spec (and at (up-to-space (subseq line (+ at 6)))))
                           (sign (and spec (position #\@ spec))))
                      (when sign
                        (push (list :text file (format nil "uses: ~A@" (subseq spec 0 sign))) items)))
                    ;; runs-on: ubuntu-24.04
                    (when (and (equal (first w) "runs-on:") (second w)
                               (not (search "${{" (second w))))
                      (push (list :text file (concatenate 'string "runs-on: "
                                                          (%key-up-to-version (second w))))
                            items))
                    ;; - os: ubuntu-24.04, as a matrix include entry
                    (when (and (equal (first w) "-") (equal (second w) "os:") (third w)
                               (not (search "${{" (third w))))
                      (push (list :text file (concatenate 'string "- os: "
                                                          (%key-up-to-version (third w))))
                            items))
                    ;; PGVECTOR_VERSION: "0.8.6" in an env block
                    (let ((key (and (first w) (> (length (first w)) 1)
                                    (char= #\: (char (first w) (1- (length (first w)))))
                                    (subseq (first w) 0 (1- (length (first w)))))))
                      (when (and key (second w)
                                 (every (lambda (c) (or (upper-case-p c) (digit-char-p c) (char= c #\_))) key)
                                 (or (%suffix-p "_VERSION" key) (%suffix-p "_COMMIT" key)))
                        (push (list :text file (format nil "~A: ~:[~;\"~]" key
                                                       (char= #\" (char (second w) 0))))
                              items)))
                    (nreverse items)))
   :test #'equal))

(defun %image-key (prefix image)
  "PREFIX followed by IMAGE's name up to and including the `:' before its tag, for an IMAGE such
as pgvector/pgvector:0.8.6-pg18@sha256:...; NIL when IMAGE has no tag."
  (let* ((name-and-tag (subseq image 0 (or (position #\@ image) (length image))))
         (colon (position #\: name-and-tag :from-end t)))
    (and colon (concatenate 'string prefix (subseq name-and-tag 0 (1+ colon))))))

(defun %compose-items ()
  "Each `image: NAME:TAG' of a compose file at the top of the tree."
  (loop for path in (sort (append (directory (merge-pathnames "docker-compose*.yml" *root*))
                                  (directory (merge-pathnames "compose*.yml" *root*)))
                          #'string< :key #'namestring)
        for file = (relative path)
        append (remove-duplicates
                (loop for line in (file-lines file)
                      for w = (words line)
                      for key = (and (not (comment-line-p line)) (equal (first w) "image:") (second w)
                                     (%image-key "image: " (second w)))
                      when key collect (list :text file key))
                :test #'equal)))

(defun %script-image-items ()
  "Each `image=NAME:TAG' of a shell script in scripts/. A value taken from elsewhere, such as
image=$2 or image=\"$(...)\", names no image and is left out."
  (loop for path in (sort (directory (merge-pathnames "scripts/*.sh" *root*)) #'string< :key #'namestring)
        for file = (relative path)
        append (remove-duplicates
                (loop for line in (file-lines file)
                      for trimmed = (string-left-trim '(#\Space #\Tab) line)
                      for value = (and (not (comment-line-p line))
                                       (> (length trimmed) 6)
                                       (string= "image=" trimmed :end2 6)
                                       (up-to-space (subseq trimmed 6)))
                      for key = (and value (plusp (length value))
                                     (not (member (char value 0) '(#\$ #\" #\')))
                                     (%image-key "image=" value))
                      when key collect (list :text file key))
                :test #'equal)))

(defun pinned-items ()
  "Every pin the tree has, as (kind file key), from the places listed in this file's header."
  (append
   (loop for path in (pin-files)
         for file = (relative path)
         append (loop for line in (file-lines file)
                      for w = (words line)
                      when (and (top-level-line-p line)
                                (or (member (first w) '("version" "sha") :test #'string=)
                                    (equal (third w) "sha256")))
                        collect (list :field file (first w))))
   (loop for line in (file-lines "scripts/versions.env")
         for key = (let ((eq (position #\= line))) (and eq (not (comment-line-p line)) (subseq line 0 eq)))
         when (and key (or (string= key "QUICKLISP_DIST") (%suffix-p "_VERSION" key)))
           collect (list :env "scripts/versions.env" key))
   (loop for path in (sort (directory (merge-pathnames ".github/workflows/*.yml" *root*))
                           #'string< :key #'namestring)
         append (%workflow-items (relative path)))
   (%compose-items)
   (%script-image-items)))

(defun covers-p (entries item)
  "Does some place of some entry name ITEM?"
  (flet ((places (entry)
           (loop for place in (getf entry :where)
                 append (if (eq (first place) :concat) (cddr place) (list place)))))
    (some (lambda (entry)
            (some (lambda (place)
                    (and (eq (first place) (first item))
                         (equal (second place) (second item))
                         (equal (third place) (third item))))
                  (places entry)))
          entries)))

;;; --- versions -------------------------------------------------------------------------------

(defun version-numbers (string)
  "The runs of digits in STRING, as integers: \"v7.0.1\" => (7 0 1), \"0.8.6-pg18\" => (0 8 6 18)."
  (let ((numbers '()) (current nil))
    (loop for c across string
          do (if (digit-char-p c)
                 (setf current (+ (* 10 (or current 0)) (digit-char-p c)))
                 (when current (push current numbers) (setf current nil))))
    (when current (push current numbers))
    (nreverse numbers)))

(defun version-shape (string)
  "STRING with each run of digits replaced by #: \"0.8.6-pg18\" => \"#.#.#-pg#\". Two versions are
compared only when they have the same shape, so a pg18 image is not compared with a pg17 one."
  (with-output-to-string (out)
    (let ((in-digits nil))
      (loop for c across string
            do (cond ((digit-char-p c) (unless in-digits (write-char #\# out)) (setf in-digits t))
                     (t (write-char c out) (setf in-digits nil)))))))

(defun version< (a b)
  "Is version string A older than B, comparing their numbers in order?"
  (loop for x in (version-numbers a)
        for y in (version-numbers b)
        do (cond ((< x y) (return t)) ((> x y) (return nil)))
        finally (return (< (length (version-numbers a)) (length (version-numbers b))))))

(defun newest (versions)
  (first (sort (copy-list versions) (lambda (a b) (version< b a)))))

(defun stable-p (version)
  "No pre-release marker: rc, alpha, beta, pre, preview, dev or next."
  (let ((v (string-downcase version)))
    (notany (lambda (marker) (search marker v)) '("rc" "alpha" "beta" "pre" "dev" "next"))))

(defun compare-pin (pinned latest)
  "(values status detail) for PINNED against LATEST. Only as many numbers as PINNED has are
compared, so a CI action pinned to its major tag v7 is current while the latest release is
v7.0.1, and behind once v8 exists."
  (let* ((p (version-numbers pinned))
         (l (subseq (version-numbers latest) 0 (min (length p) (length (version-numbers latest))))))
    (cond ((or (null p) (null l)) (values :unknown (format nil "cannot compare ~A with ~A" pinned latest)))
          ((equal p l) (values :current nil))
          ((version< (format nil "~{~D~^.~}" p) (format nil "~{~D~^.~}" l))
           (values :behind (format nil "latest is ~A" latest)))
          (t (values :current (format nil "pinned ~A is newer than the latest release ~A" pinned latest))))))


(defun base (variable default)
  (let ((v (uiop:getenv variable))) (if (and v (plusp (length v))) v default)))

(defun today ()
  "Today's date in UTC as YYYY-MM-DD, or CHECK_UPSTREAM_TODAY when it is set, which is how a test
fixes the day."
  (base "CHECK_UPSTREAM_TODAY"
        (multiple-value-bind (s m h day month year) (decode-universal-time (get-universal-time) 0)
          (declare (ignore s m h))
          (format nil "~4,'0D-~2,'0D-~2,'0D" year month day))))

(defun retired-p (entry today)
  "True when ENTRY has a :retires date on or before TODAY. Both are YYYY-MM-DD, so comparing them
as strings compares them as dates."
  (let ((retires (getf entry :retires)))
    (and (stringp retires) (string<= retires today) t)))

(defun cell (x)
  "X as the text of one Markdown table cell: a | inside a tag name or an error would end the cell
early (the hub's review of #738), so it is escaped, and a line break becomes a space."
  (with-output-to-string (out)
    (loop for c across (princ-to-string (or x ""))
          do (case c
               (#\| (write-string "\\|" out))
               ((#\Newline #\Return) (write-char #\Space out))
               (t (write-char c out))))))

(defun write-markdown (rows stream)
  (format stream "Written by `scripts/check-upstream.lisp --online` (#716). Each row is an entry in `upstream.sexp`.~%~%")
  (dolist (group '((:retired "Past its shutdown date")
                   (:behind "Behind the latest release")
                   (:unknown "Could not be checked")
                   (:held "Behind on purpose")
                   (:manual "Checked by hand")
                   (:current "Current")))
    (let ((these (remove (first group) rows :key #'fifth :test-not #'eq)))
      (when these
        (format stream "## ~A (~D)~%~%| Name | Pinned | Latest | Note |~%|---|---|---|---|~%" (second group) (length these))
        (dolist (r these)
          (format stream "| ~A | ~A | ~A | ~A |~%" (cell (first r)) (cell (third r)) (cell (fourth r)) (cell (sixth r))))
        (terpri stream)))))

;;; --- self-test -----------------------------------------------------------------------------

(defun self-test ()
  "The comparison rules on known inputs. Prints each failure and returns how many cases failed."
  (let ((cases '(("2.6.9" "2.6.9" :current) ("2.6.8" "2.6.9" :behind) ("v7" "v7.0.1" :current)
                 ("v6" "v7.0.1" :behind) ("1.9.12" "2.0.11" :behind) ("2026-01-01" "2026-01-01" :current)
                 ("2025-07-01" "2026-01-01" :behind) ("0.8.6-pg18" "0.8.7-pg18" :behind)
                 ("3.10.0" "3.9.4" :current)))
        (failed 0))
    (dolist (c cases)
      (let ((got (compare-pin (first c) (second c))))
        (unless (eq got (third c))
          (incf failed)
          (format t "  FAIL ~A against ~A: ~S, expected ~S~%" (first c) (second c) got (third c)))))
    (unless (and (string= "#.#.#-pg#" (version-shape "0.8.6-pg18")) (string= "#.#" (version-shape "24.04"))
                 (string= "2.0.11" (newest '("2.0.9" "2.0.11" "1.9.12"))) (not (stable-p "4.0.0-beta.1")))
      (incf failed)
      (format t "  FAIL version-shape, newest or stable-p~%"))
    ;; The shutdown day itself counts as past, the day before does not, and no date never does.
    (unless (and (retired-p '(:retires "2026-10-23") "2026-10-23")
                 (retired-p '(:retires "2026-10-23") "2027-01-01")
                 (not (retired-p '(:retires "2026-10-23") "2026-10-22"))
                 (not (retired-p '(:name "x") "2099-12-31")))
      (incf failed)
      (format t "  FAIL retired-p~%"))
    (format t "~A --self-test: ~D case~:P, ~D failed~%" *program* (+ 2 (length cases)) failed)
    failed))

;;; --- the offline check -------------------------------------------------------------------

(defun offline-check ()
  "Check upstream.sexp against the tree. Returns a list of (entry . value), and records each
problem in *PROBLEMS*. Signals INVENTORY-UNREADABLE when upstream.sexp cannot be read or holds
no entries."
  (let* ((path (merge-pathnames "upstream.sexp" *root*))
         (entries (handler-case (read-inventory path)
                    (error (e)
                      (error 'inventory-unreadable
                             :message (format nil "~A: cannot read ~A: ~A"
                                              *program* (human-path:human-path path) e)))))
         (checked '()))
    (when (null entries)
      (error 'inventory-unreadable
             :message (format nil "~A: ~A holds no entries" *program* (human-path:human-path path))))
    (let ((names '()))
      (dolist (entry entries)
        (let ((name (and (listp entry) (getf entry :name))))
          (when (and name (member name names :test #'equal))
            (problem "~A: two entries have this name" name))
          (push name names)
          (let ((value (and (listp entry)
                            (handler-case (check-entry entry)
                              (error (e) (problem "~A: cannot be checked: ~A" name e) nil)))))
            (when value
              (push (cons entry value) checked)
              (format t "  ~42A ~10A ~A~%" name (string-downcase (getf entry :category)) value))))))
    (let ((items (pinned-items)))
      (dolist (item items)
        (unless (covers-p entries item)
          (problem "~A ~A has no entry in upstream.sexp" (second item) (third item))))
      (format t "~%~A: ~D entr~:@P, ~D pin~:P in the tree, all covered unless listed below.~%"
              *program* (length entries) (length items)))
    (nreverse checked)))
