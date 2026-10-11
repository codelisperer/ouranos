;;;; comments.lisp --- HTML comments are removed from a document's Markdown when it is loaded (#556).
;;;;
;;;; Authors write `<!-- ... -->' in Markdown to keep a note in the file that readers do not see.
;;;; klio renders with raw HTML escaped, so before #556 such a comment appeared on the page as
;;;; visible text, and search.json and the search index carried it too. LOAD-DOCUMENT now removes
;;;; every comment from the body before anything renders or indexes it.
;;;;
;;;; Code is left alone, because a comment written inside code is part of what the code shows:
;;;; a code span, a fenced block (``` or ~~~), and an indented block (a line indented by four
;;;; spaces or a tab, after a blank line or another such line). A four-space line inside a list
;;;; item counts as code here too. That keeps a comment visible where it was meant to be hidden,
;;;; but never deletes code a reader was meant to see.

(in-package #:klio)

(defun %line-end (text start)
  "The position of the newline that ends the line starting at START, or the length of TEXT."
  (or (position #\Newline text :start start) (length text)))

(defun %blank-line-p (text start end)
  (every (lambda (c) (member c '(#\Space #\Tab #\Return))) (subseq text start end)))

(defun %indent-width (text start end)
  "How far the line from START to END is indented, counting a tab as reaching the next multiple
of four, and the position of its first other character."
  (loop with width = 0
        for i from start below end
        for c = (char text i)
        do (case c
             (#\Space (incf width))
             (#\Tab (setf width (* 4 (1+ (floor width 4)))))
             (t (return (values width i))))
        finally (return (values width end))))

(defun %fence-at (text start end)
  "When the line from START to END opens or closes a code fence, (values CHAR LENGTH FIRST): the
fence's character, how many of it there are, and where the run starts. Otherwise NIL."
  (multiple-value-bind (width first) (%indent-width text start end)
    (when (and (< width 4) (< first end) (member (char text first) '(#\` #\~)))
      (let* ((c (char text first))
             (run (- (or (position c text :start first :end end :test-not #'char=) end) first)))
        (when (and (>= run 3)
                   ;; A backtick fence's info string cannot contain a backtick.
                   (not (and (char= c #\`) (position #\` text :start (+ first run) :end end))))
          (values c run first))))))

(defun %closing-backticks (text from run)
  "The position of the next run of exactly RUN backticks at or after FROM that ends a code span,
or NIL. The search stops at a blank line, because a code span cannot cross a paragraph."
  (loop with i = from
        while (< i (length text))
        do (let ((c (char text i)))
             (cond ((char= c #\`)
                    (let ((end (or (position #\` text :start i :test-not #'char=) (length text))))
                      (when (= (- end i) run) (return i))
                      (setf i end)))
                   ((and (char= c #\Newline)
                         (%blank-line-p text (1+ i) (%line-end text (1+ i))))
                    (return nil))
                   (t (incf i))))))

(defun strip-html-comments (markdown)
  "MARKDOWN with every HTML comment, from `<!--' to the next `-->', removed. A comment may span
lines. Comments inside code spans, fenced blocks and indented blocks are kept (see the commentary
at the top of this file), and so is `\\<!--', which Markdown writes as literal text.

A comment that is never closed removes everything after its `<!--', so a note is not published
because its end was forgotten. The second value is true in that case, for the loader to warn."
  (let ((out (make-string-output-stream))
        (len (length markdown))
        (pos 0)
        (fence nil)          ; (char . length) of the open fence, or NIL
        (after-blank t)      ; the previous line was blank, or this is the first line
        (after-code nil))    ; the previous non-blank line was an indented code line
    (flet ((emit (from to) (write-string markdown out :start from :end to)))
      (loop while (< pos len)
            do (let ((eol (%line-end markdown pos)))
                 ;; At the start of a line: fences, blank lines and indented code.
                 (block line
                   (when (or (= pos 0) (char= #\Newline (char markdown (1- pos))))
                     (multiple-value-bind (fc frun ffirst) (%fence-at markdown pos eol)
                       (cond
                         (fence
                          ;; A closing fence is the same character, at least as long, and
                          ;; nothing after it on the line.
                          (when (and fc (char= fc (car fence)) (>= frun (cdr fence))
                                     (%blank-line-p markdown (+ ffirst frun) eol))
                            (setf fence nil))
                          (emit pos (min len (1+ eol))) (setf pos (1+ eol))
                          (return-from line))
                         ((%blank-line-p markdown pos eol)
                          (emit pos (min len (1+ eol))) (setf pos (1+ eol) after-blank t)
                          (return-from line))
                         ((and (>= (%indent-width markdown pos eol) 4) (or after-blank after-code))
                          (emit pos (min len (1+ eol)))
                          (setf pos (1+ eol) after-blank nil after-code t)
                          (return-from line))
                         (fc
                          (setf fence (cons fc frun) after-blank nil after-code nil)
                          (emit pos (min len (1+ eol))) (setf pos (1+ eol))
                          (return-from line))
                         (t (setf after-blank nil after-code nil)))))
                   ;; Inside a line of text.
                   (loop while (< pos len)
                         do (let ((c (char markdown pos)))
                              (cond
                                ((char= c #\Newline)
                                 (emit pos (1+ pos)) (incf pos)
                                 (return-from line))
                                ((and (char= c #\\) (< (1+ pos) len)
                                      (char/= #\Newline (char markdown (1+ pos))))
                                 (emit pos (+ pos 2)) (incf pos 2))
                                ((char= c #\`)
                                 (let* ((end (or (position #\` markdown :start pos :test-not #'char=) len))
                                        (close (%closing-backticks markdown end (- end pos))))
                                   (if close
                                       (let ((after (+ close (- end pos))))
                                         (emit pos after) (setf pos after))
                                       (progn (emit pos end) (setf pos end)))))
                                ((and (char= c #\<) (string= "<!--" markdown :start2 pos
                                                                              :end2 (min len (+ pos 4))))
                                 (let ((close (search "-->" markdown :start2 (+ pos 2))))
                                   (unless close
                                     (return-from strip-html-comments
                                       (values (get-output-stream-string out) t)))
                                   (setf pos (+ close 3))))
                                (t (emit pos (1+ pos)) (incf pos))))))))
      (values (get-output-stream-string out) nil))))
