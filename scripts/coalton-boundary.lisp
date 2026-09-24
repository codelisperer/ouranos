;;;; coalton-boundary.lisp --- which Coalton functions that take a parameterised type are called from CL (#110)
;;;;
;;;;   sbcl --script scripts/coalton-boundary.lisp          # the table, then a summary
;;;;
;;;; WHY. A Coalton function called from CL checks its arguments' outer types on entry, but not
;;;; the elements of a parameterised type: a `(List String)' holding a keyword gets past the
;;;; check, and code that trusts the element type can then return garbage or fault (#110). The
;;;; fix is a check in each CL-facing wrapper that takes such a type. This script lists the
;;;; functions that need one. It is kept in the tree because it is most of a future check that
;;;; a new CL call to such a function goes through a checked wrapper.
;;;;
;;;; HOW, AND ITS LIMITS. It reads files as text and never loads them.
;;;;
;;;;   1. Coalton regions are the forms `(coalton-toplevel ...)' and `(coalton ...)', found in
;;;;      code (comments, strings and character literals are masked out first).
;;;;   2. A candidate is a `(declare NAME SIGNATURE)' inside a coalton-toplevel whose parameter
;;;;      part (the signature before its last `->') contains a type application `(Name ...)'
;;;;      with a capitalised head, e.g. `(List String)'. A function-typed parameter such as
;;;;      `(String -> Boolean)' is reported in its own column, because what is unchecked there
;;;;      is the function's return value, which is a different question.
;;;;   3. THE RULE FOR "CALLED FROM CL": a symbol token outside every Coalton region, in a
;;;;      tracked .lisp file, that resolves to the candidate. `pkg:name' and `pkg::name' resolve
;;;;      through package names and every :local-nicknames entry in the tree; a bare `name'
;;;;      resolves in the file's current package (the last `in-package' before it) and in the
;;;;      packages that package :uses. A call site under a `tests/' directory is counted
;;;;      separately from one in source.
;;;;
;;;;   It can be wrong in both directions. A bare name that happens to equal a candidate in a
;;;;   package that :uses the candidate's package is counted as a call. A call made through
;;;;   FUNCALL of a symbol built at run time, or through a macro that expands into one, is not
;;;;   seen. Each call site is printed so a reader can check.
;;;;
;;;; Template files (cons/templates/) and vendored trees are not read.

(require :asdf)
(require :uiop)

(defpackage #:coalton-boundary (:use #:cl))
(in-package #:coalton-boundary)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))

(defun tracked-lisp-files ()
  (let ((out (uiop:run-program (list "git" "-C" (uiop:native-namestring *root*) "ls-files" "*.lisp")
                               :output '(:string :stripped t))))
    (loop for rel in (uiop:split-string out :separator '(#\Newline))
          unless (or (string= rel "")
                     (uiop:string-prefix-p "cons/templates/" rel)
                     (search "/vendor/" rel) (uiop:string-prefix-p "vendor/" rel))
            collect rel)))

;;; --- masking: which characters are code -----------------------------------------------

(defun code-mask (text)
  "A bit vector, 1 where TEXT is code and 0 inside comments, strings and character literals."
  (let* ((n (length text)) (mask (make-array n :element-type 'bit :initial-element 1)) (i 0))
    (flet ((blank (from to) (loop for k from from below (min to n) do (setf (sbit mask k) 0))))
      (loop while (< i n) do
        (let ((c (char text i)))
          (cond
            ((char= c #\;)
             (let ((e (or (position #\Newline text :start i) n))) (blank i e) (setf i e)))
            ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
             (let ((depth 1) (j (+ i 2)))
               (loop while (and (< j n) (plusp depth)) do
                 (cond ((and (< (1+ j) n) (char= (char text j) #\|) (char= (char text (1+ j)) #\#))
                        (decf depth) (incf j 2))
                       ((and (< (1+ j) n) (char= (char text j) #\#) (char= (char text (1+ j)) #\|))
                        (incf depth) (incf j 2))
                       (t (incf j))))
               (blank i j) (setf i j)))
            ((char= c #\")
             (let ((j (1+ i)))
               (loop while (and (< j n) (char/= (char text j) #\"))
                     do (incf j (if (char= (char text j) #\\) 2 1)))
               (blank i (1+ j)) (setf i (1+ j))))
            ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
             ;; #\x, or a named character such as #\Space: the character after #\ always
             ;; belongs to it, then any further constituent characters.
             (let ((j (+ i 3)))
               (loop while (and (< j n) (alphanumericp (char text j))) do (incf j))
               (blank i j) (setf i j)))
            (t (incf i))))))
    mask))

(defun matching-close (text mask open)
  "Index of the paren closing the one at OPEN, counting code characters only."
  (let ((depth 0))
    (loop for i from open below (length text)
          when (= 1 (sbit mask i))
            do (case (char text i)
                 (#\( (incf depth))
                 (#\) (decf depth) (when (zerop depth) (return i)))))))

(defun code-occurrences (text mask needle)
  "Start positions of NEEDLE in TEXT where its first character is code."
  (loop with start = 0
        for p = (search needle text :start2 start :test #'char-equal)
        while p
        when (= 1 (sbit mask p)) collect p
        do (setf start (1+ p))))

;;; --- tokens and packages -----------------------------------------------------------------

(defun constituentp (c)
  (not (or (member c '(#\Space #\Tab #\Newline #\Return #\( #\) #\' #\` #\, #\" #\;)))))

(defun token-at (text i)
  (let ((e i)) (loop while (and (< e (length text)) (constituentp (char text e))) do (incf e))
    (subseq text i e)))

(defun normalise (designator)
  (string-downcase (string-left-trim "#:" (string-trim "\"" designator))))

(defstruct pkg name (uses '()) (nicknames '()))  ; nicknames: alist (nick . package-name)

(defvar *packages* (make-hash-table :test #'equal))

(defun read-defpackages (text mask)
  (dolist (needle '("(defpackage " "(cl:defpackage " "(uiop:define-package "
                    "(coalton/utils:defstdlib-package "))
    (dolist (p (code-occurrences text mask needle))
      (let* ((end (matching-close text mask p))
             (form (subseq text p (1+ end)))
             (name (normalise (token-at form (length needle))))
             (pkg (make-pkg :name name)))
        (let ((u (search "(:use" form :test #'char-equal)))
          (when u
            (let ((close (position #\) form :start u)))
              (setf (pkg-uses pkg)
                    (mapcar #'normalise
                            (remove "" (uiop:split-string (subseq form (+ u 5) close)
                                                          :separator '(#\Space #\Newline #\Tab))
                                    :test #'string=))))))
        (let ((l (search "(:local-nicknames" form :test #'char-equal)))
          (when l
            (let ((lend (matching-close form (make-array (length form) :element-type 'bit :initial-element 1) l)))
              (loop with s = (+ l 17)
                    for o = (position #\( form :start s :end lend)
                    while o
                    do (let* ((c (position #\) form :start o))
                              (parts (remove "" (uiop:split-string (subseq form (1+ o) c)
                                                                   :separator '(#\Space #\Newline #\Tab))
                                             :test #'string=)))
                         (when (= 2 (length parts))
                           (push (cons (normalise (first parts)) (normalise (second parts)))
                                 (pkg-nicknames pkg)))
                         (setf s (1+ c)))))))
        (setf (gethash name *packages*) pkg)))))

(defun in-package-marks (text mask)
  "(position . package) for each `(in-package ...)' or `(cl:in-package ...)' in code, in order.
A file whose package uses Coalton rather than CL has to write the second form."
  (sort (loop for needle in '("(in-package " "(cl:in-package ")
              append (loop for p in (code-occurrences text mask needle)
                           collect (cons p (normalise (token-at text (+ p (length needle)))))))
        #'< :key #'car))

(defun package-at (marks pos)
  "The package of the last mark in MARKS before POS, or NIL."
  (let ((best nil))
    (loop for (p . name) in marks while (< p pos) do (setf best name))
    best))

(defun resolve-prefix (prefix current)
  "The package PREFIX names from inside CURRENT: a nickname of CURRENT, else a package name,
else a nickname any package in the tree gives it."
  (let ((cur (gethash current *packages*)))
    (or (and cur (cdr (assoc prefix (pkg-nicknames cur) :test #'string=)))
        (and (gethash prefix *packages*) prefix)
        (loop for p being the hash-values of *packages*
              thereis (cdr (assoc prefix (pkg-nicknames p) :test #'string=)))
        prefix)))

;;; --- the scan ------------------------------------------------------------------------------

(defstruct cand name package file line signature params applications function-params
  (src-calls '()) (test-calls '()))

(defun line-of (text pos) (1+ (count #\Newline text :end pos)))

(defun parameter-part (signature)
  (let ((arrow (search "->" signature :from-end t)))
    (if arrow (subseq signature 0 arrow) "")))

(defun type-applications (params)
  "Each `(Head ...)' in PARAMS whose head is capitalised and which is not a function type.
PARAMS starts with the signature's own opening paren, which is skipped."
  (let ((out '()) (mask (make-array (length params) :element-type 'bit :initial-element 1)))
    (loop for i from 1 below (length params)
          when (and (char= (char params i) #\() (< (1+ i) (length params))
                    (upper-case-p (char params (1+ i))))
            do (let* ((close (matching-close params mask i))
                      (inner (subseq params i (1+ (or close (1- (length params)))))))
                 (unless (search "->" inner) (push inner out))))
    (nreverse out)))

(defun function-type-params (params)
  (let ((out '()) (mask (make-array (length params) :element-type 'bit :initial-element 1)))
    (loop for i from 1 below (length params)
          when (char= (char params i) #\()
            do (let* ((close (matching-close params mask i))
                      (inner (and close (subseq params i (1+ close)))))
                 (when (and inner (search "->" inner)) (push inner out))))
    (nreverse out)))

(defun coalton-regions (text mask)
  (let ((out '()))
    (dolist (needle '("(coalton-toplevel" "(coalton " "(coalton:coalton " "(coalton:coalton-toplevel"))
      (dolist (p (code-occurrences text mask needle))
        (let ((e (matching-close text mask p))) (when e (push (cons p e) out)))))
    out))

(defun inside-p (pos regions) (some (lambda (r) (<= (car r) pos (cdr r))) regions))

(defun main ()
  (let ((files (mapcar (lambda (rel)
                         (let* ((text (uiop:read-file-string (merge-pathnames rel *root*)))
                                (mask (code-mask text)))
                           (list rel text mask (coalton-regions text mask))))
                       (tracked-lisp-files)))
        (cands (make-hash-table :test #'equal)))
    (dolist (f files) (destructuring-bind (rel text mask regions) f
                        (declare (ignore rel regions)) (read-defpackages text mask)))
    ;; Candidates.
    (dolist (f files)
      (destructuring-bind (rel text mask regions) f
        (dolist (r regions)
          (when (uiop:string-prefix-p "(coalton-toplevel" (subseq text (car r) (min (length text) (+ (car r) 17))))
            (dolist (d (code-occurrences (subseq text (car r) (1+ (cdr r)))
                                         (subseq mask (car r) (1+ (cdr r))) "(declare "))
              (let* ((p (+ (car r) d))
                     (e (matching-close text mask p))
                     (name (string-downcase (token-at text (+ p 9))))
                     (sig (string-trim '(#\Space #\Tab #\Newline #\Return)
                                       (subseq text (+ p 9 (length name)) e)))
                     (params (parameter-part sig))
                     (pkg (package-at (in-package-marks text mask) p)))
                (when (and pkg (not (string= name "")))
                  (setf (gethash (cons pkg name) cands)
                        (make-cand :name name :package pkg :file rel :line (line-of text p)
                                   :signature (substitute #\Space #\Newline sig)
                                   :params params
                                   :applications (type-applications params)
                                   :function-params (function-type-params params))))))))))
    ;; Call sites from CL.
    (dolist (f files)
      (destructuring-bind (rel text mask regions) f
        (let ((testp (search "tests/" rel)) (marks (in-package-marks text mask)))
          (loop with i = 0 while (< i (length text)) do
            (if (and (= 1 (sbit mask i)) (constituentp (char text i))
                     (or (zerop i) (not (constituentp (char text (1- i))))))
                (let* ((tok (string-downcase (token-at text i)))
                       (colon (position #\: tok)))
                  (unless (or (inside-p i regions) (zerop (length tok)) (eql colon 0))
                    (let* ((current (package-at marks i))
                           (name (if colon (string-left-trim ":" (subseq tok colon)) tok))
                           (pkgs (if colon
                                     (list (resolve-prefix (subseq tok 0 colon) current))
                                     (and current
                                          (cons current (let ((c (gethash current *packages*)))
                                                          (and c (pkg-uses c))))))))
                      (dolist (pk pkgs)
                        (let ((c (gethash (cons pk name) cands)))
                          (when c
                            (let ((site (format nil "~A:~D" rel (line-of text i))))
                              (if testp (pushnew site (cand-test-calls c) :test #'string=)
                                  (pushnew site (cand-src-calls c) :test #'string=))))))))
                  (incf i (max 1 (length (token-at text i)))))
                (incf i))))))
    ;; Report.
    (let* ((all (loop for c being the hash-values of cands collect c))
           (param-typed (remove-if-not (lambda (c) (or (cand-applications c) (cand-function-params c))) all))
           (applied (remove-if-not #'cand-applications all))
           (sorted (sort (copy-list param-typed) #'string< :key (lambda (c) (format nil "~A ~A" (cand-file c) (cand-name c))))))
      (format t "~&=== Coalton functions whose parameters include a parameterised or function type ===~%~%")
      (dolist (c sorted)
        (format t "~A  ~A:~D~%    ~A~%" (cand-name c) (cand-file c) (cand-line c) (cand-signature c))
        (when (cand-applications c)
          (format t "    parameterised: ~{~A~^  ~}~%" (cand-applications c)))
        (when (cand-function-params c)
          (format t "    function-typed: ~{~A~^  ~}~%" (cand-function-params c)))
        (format t "    called from CL in source: ~:[no~;~:*~{~A~^, ~}~]~%" (reverse (cand-src-calls c)))
        (format t "    called from CL in tests:  ~:[no~;~:*~{~A~^, ~}~]~%~%" (reverse (cand-test-calls c))))
      (format t "=== summary ===~%")
      (format t "  ~4D  declares in coalton-toplevel forms~%" (length all))
      (format t "  ~4D  with a parameterised type among the parameters~%" (length applied))
      (format t "  ~4D    of which called from CL in source~%" (count-if #'cand-src-calls applied))
      (format t "  ~4D    of which called from CL only in tests~%"
              (count-if (lambda (c) (and (null (cand-src-calls c)) (cand-test-calls c))) applied))
      (format t "  ~4D  with a function-typed parameter and no parameterised one~%"
              (count-if (lambda (c) (and (null (cand-applications c)) (cand-function-params c))) all))
      (format t "~%  parameterised types among the parameters of functions called from CL in source:~%")
      (let ((heads (make-hash-table :test #'equal)))
        (dolist (c applied)
          (when (cand-src-calls c)
            (dolist (a (cand-applications c))
              (incf (gethash (token-at a 1) heads 0)))))
        (loop for (h . n) in (sort (loop for k being the hash-keys of heads using (hash-value v) collect (cons k v))
                                   #'> :key #'cdr)
              do (format t "    ~4D  ~A~%" n h))))))

(main)
