;;;; check-format-continuations.lisp --- no FORMAT ~<newline> continuations in the tree (#146).
;;;;
;;;; Run:  sbcl --script scripts/check-format-continuations.lisp
;;;;
;;;; AGENTS.md and CLAUDE.md say never to write a FORMAT `~<newline>' continuation, and
;;;; .gitattributes says the source avoids them. The reason: in a checkout with CRLF line
;;;; endings the directive becomes `~<Return>', which FORMAT rejects, and SBCL reports it as a
;;;; compile-time "macroexpansion" error in whatever file holds it. `* text=auto eol=lf' in
;;;; .gitattributes stops that for every git checkout. The rule is the defence for a tree that
;;;; did not arrive through git -- a zip download, a copy made by a tool, an editor that
;;;; rewrote line endings -- and until this checker nothing enforced it: #146 counted 53 on
;;;; main, and there were more by the time it was taken.
;;;;
;;;; WHAT IT LOOKS FOR. Inside a string literal, a tilde, optionally followed by `:' or `@',
;;;; then a line ending (LF, or CR). Those are the three continuation directives: `~<newline>',
;;;; `~:<newline>' and `~@<newline>'. `~~' is a literal tilde and is skipped, so a string that
;;;; ends a line with `~~' is not reported.
;;;;
;;;; IT READS THE FILE AS LISP TEXT, NOT AS LINES, because a grep for a line ending in `~'
;;;; finds the wrong things. A tilde at the end of a `;' comment ("foo.lisp~", an editor
;;;; backup) is not in a string, and neither is one in a `#| |#' block comment, a `#\~'
;;;; character or a `|symbol~|'. So the scan tracks those states, including a `\' escape
;;;; inside a string, and `#\"' and `#\;', which would otherwise open a string or a comment.
;;;;
;;;; EVERY STRING LITERAL COUNTS, not only those passed to FORMAT, because which strings end up
;;;; as control strings cannot be known from the text: ERROR, WARN, a condition's :report and
;;;; FORMATTER all take them, and a string can be passed through a variable. A docstring that
;;;; ended a line with a tilde would be reported too; none in this tree does.
;;;;
;;;; IT WALKS THE FILESYSTEM for .lisp and .asd files, skipping .git and ASDF's default
;;;; exclusions, so it checks what SBCL would compile, tracked or not.

(require :asdf)
(require :uiop)

(defpackage #:check-format-continuations (:use #:cl))
(in-package #:check-format-continuations)

(defvar *root*
  ;; Device-preserving, as in check-asd-collisions.lisp: a root rebuilt from directory parts
  ;; alone loses the drive on Windows (pre-publication issue 482).
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *skipped-directories*
  (cons ".git" asdf/source-registry:*default-source-registry-exclusions*))

(defun source-files (&optional (dir *root*))
  "Every .lisp and .asd file under DIR, outside the skipped directories."
  (let ((files '()))
    (uiop:collect-sub*directories
     dir
     (constantly t)
     (lambda (d)
       (let ((name (car (last (pathname-directory d)))))
         (not (and (stringp name) (member name *skipped-directories* :test #'string=)))))
     (lambda (d)
       (dolist (f (uiop:directory-files d))
         (when (member (pathname-type f) '("lisp" "asd") :test #'equal)
           (push f files)))))
    (sort files #'string< :key #'namestring)))

(defun read-text (path)
  "PATH's contents. Latin-1 so that any byte reads as one character: the scan only cares
about ASCII punctuation, and a UTF-8 decoding error must not stop the check."
  (with-open-file (in path :external-format :latin-1)
    (let* ((text (make-string (file-length in)))
           (n (read-sequence text in)))
      (subseq text 0 n))))

(defun continuations (text)
  "Every FORMAT continuation directive inside a string literal in TEXT, as a list of
(line column directive), with line and column counted from 1. DIRECTIVE is \"~\", \"~:\"
or \"~@\" (with both modifiers it is reported as written)."
  (let ((found '())
        (state :code)
        (block-depth 0)
        (line 1)
        (column 0)
        (i 0)
        (n (length text)))
    (flet ((at (k) (and (< k n) (char text k))))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (case state
                   (:code
                    (cond ((char= c #\") (setf state :string))
                          ((char= c #\;) (setf state :line-comment))
                          ((char= c #\|) (setf state :pipe-symbol))
                          ((and (char= c #\#) (eql (at (1+ i)) #\|))
                           (setf state :block-comment block-depth 1)
                           (incf i) (incf column))
                          ((and (char= c #\#) (eql (at (1+ i)) #\\))
                           ;; #\x: step onto the character it names, which may be a quote, a
                           ;; semicolon or a bar; the step at the end of the loop moves past it.
                           (incf i 2) (incf column 2))))
                   (:string
                    ;; A backslash: step onto the escaped character; the step at the end of
                    ;; the loop moves past it (and counts it if it is a newline).
                    (cond ((char= c #\\) (incf i) (incf column))
                          ((char= c #\") (setf state :code))
                          ((char= c #\~)
                           (let ((j (1+ i)))
                             (if (eql (at j) #\~)
                                 (progn (incf i) (incf column))  ; ~~ is a literal tilde
                                 (progn
                                   (loop while (member (at j) '(#\: #\@)) do (incf j))
                                   (when (member (at j) '(#\Newline #\Return))
                                     (push (list line (1+ column) (subseq text i j)) found))))))))
                   (:line-comment
                    (when (char= c #\Newline) (setf state :code)))
                   (:pipe-symbol
                    (cond ((char= c #\\) (incf i) (incf column))
                          ((char= c #\|) (setf state :code))))
                   (:block-comment
                    (cond ((and (char= c #\|) (eql (at (1+ i)) #\#))
                           (decf block-depth) (incf i) (incf column)
                           (when (zerop block-depth) (setf state :code)))
                          ((and (char= c #\#) (eql (at (1+ i)) #\|))
                           (incf block-depth) (incf i) (incf column)))))
                 (when (and (< i n) (char= (char text i) #\Newline))
                   (incf line) (setf column -1))
                 (incf i) (incf column))))
    (nreverse found)))

(defun relative (path)
  (enough-namestring path *root*))

(defun main ()
  (let* ((files (source-files))
         (hits (loop for f in files
                     nconc (loop for (line column directive) in (continuations (read-text f))
                                 collect (list (relative f) line column directive)))))
    (cond
      ((null files)
       ;; A checker that passes because it read nothing is the failure this block of the gate
       ;; exists to catch, so an empty tree is an error, not a pass.
       (format t "FAIL -- no .lisp or .asd files found under ~A~%" (uiop:native-namestring *root*))
       (uiop:quit 1))
      ((null hits)
       (format t "ok -- ~D .lisp and .asd files, no FORMAT ~~<newline> continuation in a string~%"
               (length files))
       (uiop:quit 0))
      (t
       (dolist (h hits)
         (destructuring-bind (file line column directive) h
           (format t "~A:~D:~D: ~A<newline> continuation inside a string~%"
                   file line column directive)))
       (format t "FAIL -- ~D FORMAT continuation~:P in ~D file~:P. A CRLF checkout turns each into an illegal ~~<Return> directive. Fold each control string onto one line (AGENTS.md, House style).~%"
               (length hits) (length (remove-duplicates hits :key #'first :test #'string=)))
       (uiop:quit 1)))))

(main)
