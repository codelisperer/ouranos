;;;; check-upstream.lisp --- every pinned version in the tree has an entry in upstream.sexp, and
;;;; every entry still finds its pin (#716).
;;;;
;;;;     sbcl --script scripts/check-upstream.lisp     ; offline, deterministic
;;;;
;;;; Exit 0 when the inventory and the tree agree, 1 when they do not, 2 when upstream.sexp
;;;; cannot be read at all, so a misread inventory is never reported as a clean one.
;;;;
;;;; WHAT IT CHECKS, all without the network:
;;;;
;;;;   1. Every entry in upstream.sexp is well formed: a unique name, a known category, at
;;;;      least one place in :WHERE, a known :UPSTREAM form, and a :REVIEWED date or :NEVER
;;;;      when the upstream is :MANUAL.
;;;;   2. Every place an entry names still yields a value, and all of them yield the same one.
;;;;      A pin that moved, or a second copy of a version that was not updated with the first
;;;;      (libuv.pin and build-libuv.lisp, ASSETS.pin and assets.lisp), fails here.
;;;;   3. Every pin in the tree has an entry: each identity line of each *.pin file (`version'
;;;;      or `sha', or an ASSETS.pin-style `NAME VERSION sha256 HASH' line), each *_VERSION key
;;;;      and QUICKLISP_DIST in scripts/versions.env, and each `uses: ACTION@' in each workflow.
;;;;      A pin added without an entry fails here, in the commit that added it.
;;;;
;;;; WHAT IT DOES NOT DO: ask whether upstream has a newer release. That needs the network and
;;;; belongs in a scheduled job, not in a gate that must be reproducible offline
;;;; (docs/versioning-and-pinning.md). It is the second step of #716.

(require :uiop)
(load (merge-pathnames "human-path.lisp" (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))   ; how a path is printed (#168)

(defparameter *root* (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *categories* '(:toolchain :quicklisp :native :asset :api :ci :container))

(defparameter *upstream-kinds*
  '(:github-release :github-commit :npm :sourceforge :nuget :quicklisp-dist :docker :manual))

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
  "Every *.pin file in the tree, outside .git."
  (sort (remove-if (lambda (p) (search "/.git/" (namestring p)))
                   (directory (merge-pathnames "**/*.pin" *root*)))
        #'string< :key #'namestring))

(defun pinned-items ()
  "Every pin the tree has, as (kind file key): an identity line of a *.pin file, a version key
of scripts/versions.env, and an action a workflow uses."
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
         when (and key (or (string= key "QUICKLISP_DIST")
                           (let ((suffix "_VERSION"))
                             (and (> (length key) (length suffix))
                                  (string= suffix key :start2 (- (length key) (length suffix)))))))
           collect (list :env "scripts/versions.env" key))
   (loop for path in (sort (directory (merge-pathnames ".github/workflows/*.yml" *root*))
                           #'string< :key #'namestring)
         for file = (relative path)
         append (remove-duplicates
                 (loop for line in (file-lines file)
                       for at = (search "uses: " line)
                       for spec = (and at (not (comment-line-p line)) (up-to-space (subseq line (+ at 6))))
                       for sign = (and spec (position #\@ spec))
                       when sign
                         collect (list :text file (format nil "uses: ~A@" (subseq spec 0 sign))))
                 :test #'equal))))

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

;;; --- main ----------------------------------------------------------------------------------

(defun main ()
  (let* ((path (merge-pathnames "upstream.sexp" *root*))
         (entries (handler-case (read-inventory path)
                    (error (e)
                      (format *error-output* "check-upstream: cannot read ~A: ~A~%"
                              (human-path:human-path path) e)
                      (uiop:quit 2)))))
    (when (null entries)
      (format *error-output* "check-upstream: ~A holds no entries~%" (human-path:human-path path))
      (uiop:quit 2))
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
              (format t "  ~32A ~12A ~A~%" name (string-downcase (getf entry :category)) value))))))
    (let ((items (pinned-items)))
      (dolist (item items)
        (unless (covers-p entries item)
          (problem "~A ~A has no entry in upstream.sexp" (second item) (third item))))
      (format t "~%check-upstream: ~D entr~:@P, ~D pin~:P in the tree, all covered unless listed below.~%"
              (length entries) (length items)))
    (cond ((null *problems*)
           (format t "check-upstream: upstream.sexp and the tree agree.~%")
           (uiop:quit 0))
          (t
           (dolist (p (reverse *problems*))
             (format t "  PROBLEM ~A~%" p))
           (format t "check-upstream: ~D problem~:P. See upstream.sexp's header.~%" (length *problems*))
           (uiop:quit 1)))))

(main)
