;;;; comments.lisp --- HTML comments are removed from a document's Markdown when it is loaded (#556).
;;;;
;;;; Authors write `<!-- ... -->' in Markdown to keep a note in the file that readers do not see.
;;;; klio renders with raw HTML escaped, so before #556 such a comment appeared on the page as
;;;; visible text, and search.json and the search index carried it too. LOAD-DOCUMENT now removes
;;;; every comment from the body before anything renders or indexes it.
;;;;
;;;; Code is left alone, because a comment written inside code is part of what the code shows:
;;;; a code span, a fenced block (``` or ~~~), and an indented block (a line indented by four
;;;; spaces or a tab, after a blank line or another such line). A fence or an indented block
;;;; inside a block quote (`> ```') is found after the quote's `>' markers, and a fence may open
;;;; on a list item's first line (`- ```'); its lines then belong to the item while they are
;;;; indented as far as the item's text.
;;;;
;;;; Inside a list item, hyperion/markdown reads a line indented by four to seven spaces after a
;;;; blank line as more of the item's text, not as code, so a comment there shows on the page.
;;;; Such a line is still kept as written, because telling it from code takes more of Markdown
;;;; than this file parses, and deleting code is worse than showing a note. The line's number is
;;;; returned, and LOAD-DOCUMENT warns about it.

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

(defun %strip-quote-markers (text start end &optional limit)
  "Skip the block-quote markers at the start of the line from START to END, each up to three
spaces, `>' and one optional space, but no more than LIMIT of them when LIMIT is given. Return
the position after them and how many there were."
  (loop with pos = start
        for depth from 0
        do (multiple-value-bind (width first) (%indent-width text pos end)
             (if (and (or (null limit) (< depth limit))
                      (< width 4) (< first end) (char= #\> (char text first)))
                 (setf pos (if (and (< (1+ first) end) (char= #\Space (char text (1+ first))))
                               (+ first 2)
                               (1+ first)))
                 (return (values pos depth))))))

(defun %list-marker-end (text start end)
  "When the line from START to END starts a list item (up to three spaces, then -, * or +, or a
number followed by . or ), and then a space, a tab or the end of the line), the position where
the item's text starts: after the marker and the spaces after it, or after one space when there
are more than four. Otherwise NIL."
  (multiple-value-bind (width first) (%indent-width text start end)
    (when (and (< width 4) (< first end))
      (let ((after (cond ((member (char text first) '(#\- #\* #\+)) (1+ first))
                         ((digit-char-p (char text first))
                          (let ((p (position-if-not #'digit-char-p text :start first :end end)))
                            (and p (member (char text p) '(#\. #\))) (1+ p)))))))
        (when (and after (or (= after end) (member (char text after) '(#\Space #\Tab))))
          (let ((spaces (- (or (position #\Space text :start after :end end :test-not #'char=) end)
                           after)))
            (if (<= 1 spaces 4) (+ after spaces) (min end (1+ after)))))))))

(defun %list-item-p (text start end)
  "Whether the line from START to END starts a list item (see %LIST-MARKER-END)."
  (and (%list-marker-end text start end) t))

(defun %fence-open (text start end)
  "When the line from START to END, read after its block-quote markers, opens a code fence, the
fence as (CHAR LENGTH DEPTH INDENT): its character, how many of it there are, how many
block-quote markers come before it, and, when it opens on a list item's first line, how far the
item's text is indented after those markers, or 0. Otherwise NIL."
  (multiple-value-bind (pos depth) (%strip-quote-markers text start end)
    (multiple-value-bind (c run) (%fence-at text pos end)
      (if c
          (list c run depth 0)
          (let ((content (%list-marker-end text pos end)))
            (when content
              (multiple-value-bind (c run) (%fence-at text content end)
                (when c (list c run depth (- content pos))))))))))

(defun %fence-line (text start end fence)
  "What the line from START to END is to FENCE, an open fence from %FENCE-OPEN: :CLOSE when it
closes it, :INSIDE when it is a line of the fenced block, and :LEAVE when the block ended before
it, because the line has fewer block-quote markers than the fence, or is not blank and is
indented less than the list item the fence opened in."
  (destructuring-bind (fc frun depth indent) fence
    (multiple-value-bind (pos found) (%strip-quote-markers text start end depth)
      (cond ((< found depth) :leave)
            ((%blank-line-p text pos end) :inside)
            ((< (%indent-width text pos end) indent) :leave)
            (t (let ((from (loop for i from pos below (min end (+ pos indent))
                                 while (char= #\Space (char text i))
                                 finally (return i))))
                 (multiple-value-bind (c run first) (%fence-at text from end)
                   (if (and c (char= c fc) (>= run frun) (%blank-line-p text (+ first run) end))
                       :close
                       :inside))))))))

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
because its end was forgotten. The second value is true in that case, for the loader to warn.
The third value lists, by line number in MARKDOWN, each indented line of a list item that was
kept and has a `<!--' in it; the page shows that comment."
  (let ((out (make-string-output-stream))
        (len (length markdown))
        (pos 0)
        (fence nil)          ; the open fence, as %FENCE-OPEN returns it, or NIL
        (after-blank t)      ; the previous line was blank, or this is the first line
        (after-code nil)     ; the previous non-blank line was an indented code line
        (in-list nil)        ; inside a list item, as far as the lines read so far show
        (shown '()))         ; line numbers of list-item lines kept with a comment in them
    (flet ((emit (from to) (write-string markdown out :start from :end to)))
      (loop while (< pos len)
            do (let ((eol (%line-end markdown pos)))
                 ;; At the start of a line: fences, blank lines and indented code.
                 (block line
                   (when (or (= pos 0) (char= #\Newline (char markdown (1- pos))))
                     (let ((state (and fence (%fence-line markdown pos eol fence))))
                       (when (member state '(:inside :close))
                         (when (eq state :close) (setf fence nil))
                         (emit pos (min len (1+ eol))) (setf pos (1+ eol))
                         (return-from line))
                       ;; The fenced block ended before this line, which is read as any other.
                       (when (eq state :leave) (setf fence nil)))
                     ;; Blank lines and indented code are judged after any block-quote markers.
                     (let ((cpos (%strip-quote-markers markdown pos eol))
                           (opened (%fence-open markdown pos eol)))
                       (cond
                         ((%blank-line-p markdown cpos eol)
                          (emit pos (min len (1+ eol))) (setf pos (1+ eol) after-blank t)
                          (return-from line))
                         ((and in-list (<= 4 (%indent-width markdown cpos eol) 7) after-blank)
                          ;; The renderer reads this as the item's text (see the top of the file).
                          (when (search "<!--" markdown :start2 pos :end2 eol)
                            (push (1+ (count #\Newline markdown :end pos)) shown))
                          (emit pos (min len (1+ eol)))
                          (setf pos (1+ eol) after-blank nil after-code nil)
                          (return-from line))
                         ((and (>= (%indent-width markdown cpos eol) 4) (or after-blank after-code))
                          (emit pos (min len (1+ eol)))
                          (setf pos (1+ eol) after-blank nil after-code t)
                          (return-from line))
                         (opened
                          (setf fence opened after-blank nil after-code nil)
                          (when (plusp (fourth opened)) (setf in-list t))
                          (emit pos (min len (1+ eol))) (setf pos (1+ eol))
                          (return-from line))
                         (t
                          (cond ((%list-item-p markdown cpos eol) (setf in-list t))
                                ((and after-blank (< (%indent-width markdown cpos eol) 4))
                                 (setf in-list nil)))
                          (setf after-blank nil after-code nil)))))
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
                                       (values (get-output-stream-string out) t (nreverse shown))))
                                   (setf pos (+ close 3))))
                                (t (emit pos (1+ pos)) (incf pos))))))))
      (values (get-output-stream-string out) nil (nreverse shown)))))
