;;;; frontmatter.lisp --- parse a content file's front-matter (pre-publication issue 359 Q1: answer B).
;;;;
;;;; TYPED CORE PLUS A NAMED `extra'. The core is title, date, slug, tags, draft and
;;;; publish-at. Everything else lands in `extra', named as such, so a reader can see exactly
;;;; where the engine's knowledge of a document stops.
;;;;
;;;; `extra' CARRIES NESTED VALUES, which is not a refinement -- it is what the first real
;;;; document requires. A CV role's bullets are a list of objects, each with an optional list
;;;; of metric objects, because the consumer selects bullets by relevance and needs a metric
;;;; as a number rather than a substring to parse back out of a sentence. A flat
;;;; string-to-string `extra' fails on that document.
;;;;
;;;; A DOCUMENTED SUBSET, NOT YAML. There is no YAML parser in this tree and adding one means
;;;; cl-yaml, which binds the C library libyaml -- a new external dependency and a new native
;;;; dependency, which is the maintainer's call and not a thing to slip in under a content
;;;; feature. So this parses the subset real content uses and REFUSES everything else by
;;;; name. Refusing is the whole safety property: a parser that guesses at a construct it
;;;; does not understand produces content that is wrong rather than content that is absent,
;;;; and nothing downstream can tell.
;;;;
;;;; Supported: nested maps by indentation; block sequences (`- item`) of scalars and of
;;;; maps; flow sequences of scalars (`[a, b]`), INCLUDING ONES WRAPPED ACROSS LINES; quoted
;;;; and bare scalars; integers; true, false, null; `#` comments.
;;;;
;;;; The wrapped flow sequence is here because the first real content file needed it and
;;;; nothing else did: a controlled list of skills does not fit one line and an author wraps
;;;; it, as YAML allows. Requiring the `]` on the opening line rejected a file that every
;;;; other YAML reader accepts, which is the failure mode this subset is least entitled to --
;;;; refusing what we do not understand is defensible, refusing what we DO understand because
;;;; of where a newline fell is not.
;;;;
;;;; Refused by name: anchors and aliases, multi-line scalars (`|`, `>`), flow MAPPINGS
;;;; (`{a: b}`), multiple documents, and tabs used for indentation.

(in-package #:klio)

(define-condition unterminated-front-matter (error)
  ((file :initarg :file :initform nil :reader unterminated-front-matter-file))
  (:report (lambda (c s)
             (format s "klio: front-matter was opened with --- and never closed~@[ in ~A~]."
                     (unterminated-front-matter-file c)))))

(define-condition unsupported-front-matter (error)
  ((construct :initarg :construct :reader unsupported-front-matter-construct)
   (line :initarg :line :initform nil :reader unsupported-front-matter-line)
   (text :initarg :text :initform nil :reader unsupported-front-matter-text)
   (file :initarg :file :initform nil :reader unsupported-front-matter-file))
  (:report
   (lambda (c s)
     (format s "klio: front-matter uses ~A, which this parser does not support~@[ (~A~@[, line ~D~])~].~%~%~
This is a documented subset rather than YAML. Refusing is deliberate: a parser that guessed ~
at a construct it does not understand would produce content that is WRONG rather than ~
content that is absent, and nothing downstream could tell.~@[~%~%  ~A~]"
             (unsupported-front-matter-construct c)
             (unsupported-front-matter-file c)
             (unsupported-front-matter-line c)
             (unsupported-front-matter-text c)))))

(defun %delimiter-p (line)
  (string= "---" (string-trim '(#\Space #\Tab #\Return) line)))

(defun split-front-matter (text &key file)
  "Return (values FRONT-MATTER-TEXT BODY). FRONT-MATTER-TEXT is NIL when there is none.

A file whose front-matter is opened and never closed is an error, not a file without any:
the author meant to write front-matter, and treating the whole file as body would publish
the metadata as prose."
  (let ((lines (uiop:split-string text :separator '(#\Newline))))
    (if (or (null lines) (not (%delimiter-p (first lines))))
        (values nil text)
        (let ((end (position-if #'%delimiter-p lines :start 1)))
          (unless end (error 'unterminated-front-matter :file file))
          (values (format nil "~{~A~^~%~}" (subseq lines 1 end))
                  (format nil "~{~A~^~%~}" (nthcdr (1+ end) lines)))))))

;;; --- the subset parser ------------------------------------------------------

(defstruct (fm-line (:constructor %fm-line (indent text number)))
  (indent 0 :type fixnum :read-only t)
  (text "" :type string :read-only t)
  (number 0 :type fixnum :read-only t))

(defun %strip-comment (line)
  "LINE without a trailing `#' comment, respecting quotes."
  (let ((in-single nil) (in-double nil))
    (loop for i from 0 below (length line)
          for ch = (char line i)
          do (cond ((and (char= ch #\') (not in-double)) (setf in-single (not in-single)))
                   ((and (char= ch #\") (not in-single)) (setf in-double (not in-double)))
                   ((and (char= ch #\#) (not in-single) (not in-double)
                         (or (zerop i) (member (char line (1- i)) '(#\Space #\Tab))))
                    (return-from %strip-comment (subseq line 0 i)))))
    line))

(defun %scan-lines (text file)
  "TEXT as FM-LINEs, comments and blanks removed."
  (loop for raw in (uiop:split-string text :separator '(#\Newline))
        for n from 1
        for stripped = (string-right-trim '(#\Space #\Tab #\Return) (%strip-comment raw))
        unless (zerop (length (string-trim '(#\Space #\Tab) stripped)))
          collect (let* ((ws (or (position-if-not (lambda (c) (member c '(#\Space #\Tab)))
                                                 stripped)
                                 (length stripped)))
                         (indent (or (position-if-not (lambda (c) (char= c #\Space)) stripped) 0)))
                    ;; The whitespace RUN, not the space run. Measuring only spaces meant a
                    ;; line starting with a tab had indent 0, so the slice checked here was
                    ;; empty and the guard could never fire on the case it was written for.
                    (when (find #\Tab (subseq stripped 0 ws))
                      (error 'unsupported-front-matter :construct "a tab in the indentation"
                                                       :line n :text raw :file file))
                    (%fm-line indent (subseq stripped indent) n))))

(defun %flow-depth (text)
  "How many flow sequences TEXT leaves open: `[' minus `]', counting only outside quotes.

Outside quotes matters -- a skill named \"C[++]\" is a string, not a bracket -- and this is
the same quote-tracking %STRIP-COMMENT and %SPLIT-FLOW do, for the same reason."
  (let ((depth 0) (in-single nil) (in-double nil))
    (loop for ch across text
          do (cond ((and (char= ch #\') (not in-double)) (setf in-single (not in-single)))
                   ((and (char= ch #\") (not in-single)) (setf in-double (not in-double)))
                   ((and (char= ch #\[) (not in-single) (not in-double)) (incf depth))
                   ((and (char= ch #\]) (not in-single) (not in-double)) (decf depth))))
    depth))

(defun %join-flow-lines (lines file)
  "LINES with each wrapped flow sequence joined into one logical line.

A flow sequence may be written across several lines, and real content does:

    skills: [\"Agentic systems\", \"Agent memory\",
             \"Python\", \"C#\"]

Joining happens HERE, before any value is parsed, so %PARSE-SCALAR and %SPLIT-FLOW keep
seeing one line and know nothing about wrapping. The joined line keeps the FIRST line's
number, because that is where a reader looking for the construct will start.

A sequence that is never closed is still refused -- the same construct name as before, so
what was an error about the end of a LINE is now an error about the end of the FRONT-MATTER,
which is what it always meant."
  (let ((out '()))
    (loop while lines
          do (let* ((line (pop lines))
                    (text (fm-line-text line)))
               (when (plusp (%flow-depth text))
                 (loop while (plusp (%flow-depth text))
                       do (unless lines
                            (error 'unsupported-front-matter
                                   :construct "an unclosed flow sequence"
                                   :line (fm-line-number line) :text text :file file))
                          (setf text (concatenate 'string text " "
                                                  (fm-line-text (pop lines))))))
               (push (%fm-line (fm-line-indent line) text (fm-line-number line)) out)))
    (nreverse out)))

(defun %parse-scalar (text line file)
  "TEXT as a value: string, integer, boolean, null, or a flow sequence of scalars."
  (let ((s (string-trim '(#\Space #\Tab) text)))
    (cond
      ((zerop (length s)) nil)
      ((find (char s 0) "&*")
       (error 'unsupported-front-matter :construct "an anchor or alias" :line line :text text :file file))
      ((find (char s 0) "|>")
       (error 'unsupported-front-matter :construct "a multi-line scalar" :line line :text text :file file))
      ((char= (char s 0) #\{)
       (error 'unsupported-front-matter :construct "a flow mapping" :line line :text text :file file))
      ((char= (char s 0) #\[)
       (unless (char= (char s (1- (length s))) #\])
         (error 'unsupported-front-matter :construct "an unclosed flow sequence" :line line :text text :file file))
       (let ((inner (string-trim '(#\Space #\Tab) (subseq s 1 (1- (length s))))))
         (if (zerop (length inner))
             '()
             (mapcar (lambda (item) (%parse-scalar item line file))
                     (%split-flow inner line file)))))
      ((and (>= (length s) 2) (char= (char s 0) #\") (char= (char s (1- (length s))) #\"))
       (subseq s 1 (1- (length s))))
      ((and (>= (length s) 2) (char= (char s 0) #\') (char= (char s (1- (length s))) #\'))
       (subseq s 1 (1- (length s))))
      ((string-equal s "null") nil)
      ((string-equal s "true") t)
      ((string-equal s "false") :false)
      ((every (lambda (c) (or (digit-char-p c) (char= c #\-))) s)
       (or (ignore-errors (parse-integer s)) s))
      (t s))))

(defun %split-flow (inner line file)
  "Split a flow sequence's contents on commas that are not inside quotes."
  (let ((parts '()) (start 0) (in-single nil) (in-double nil))
    (loop for i from 0 below (length inner)
          for ch = (char inner i)
          do (cond ((and (char= ch #\') (not in-double)) (setf in-single (not in-single)))
                   ((and (char= ch #\") (not in-single)) (setf in-double (not in-double)))
                   ((char= ch #\[)
                    (error 'unsupported-front-matter :construct "a nested flow sequence"
                                                     :line line :text inner :file file))
                   ((and (char= ch #\,) (not in-single) (not in-double))
                    (push (subseq inner start i) parts)
                    (setf start (1+ i)))))
    (push (subseq inner start) parts)
    (nreverse parts)))

(defun %key-and-rest (text line file)
  "(values KEY REST) for `key: rest', or NIL when TEXT is not a mapping entry."
  (let ((colon (position #\: text)))
    (when (and colon (plusp colon))
      (let ((key (string-trim '(#\Space #\Tab) (subseq text 0 colon))))
        (when (find #\Space key)
          ;; "a b: c" is not a key we accept; a bare scalar containing a colon reaches here
          ;; too, and guessing which one it is is exactly what this parser refuses to do.
          (error 'unsupported-front-matter :construct "a key containing a space"
                                           :line line :text text :file file))
        (values (string-downcase key)
                (string-trim '(#\Space #\Tab) (subseq text (1+ colon))))))))

(defun %parse-block (lines indent file)
  "Parse the block of LINES at INDENT. Returns (values VALUE REMAINING)."
  (if (and lines (string= "- " (subseq (fm-line-text (first lines))
                                       0 (min 2 (length (fm-line-text (first lines)))))))
      (%parse-sequence lines indent file)
      (%parse-mapping lines indent file)))

(defun %parse-mapping (lines indent file)
  (let ((pairs '()))
    (loop
      (let ((line (first lines)))
        (when (or (null line) (< (fm-line-indent line) indent)) (return))
        (multiple-value-bind (key rest)
            (%key-and-rest (fm-line-text line) (fm-line-number line) file)
          (unless key
            (error 'unsupported-front-matter :construct "a line that is neither a mapping nor a sequence entry"
                                             :line (fm-line-number line)
                                             :text (fm-line-text line) :file file))
          (pop lines)
          (if (plusp (length rest))
              (push (cons key (%parse-scalar rest (fm-line-number line) file)) pairs)
              ;; the value is the indented block beneath
              (let ((child-indent (and (first lines) (fm-line-indent (first lines)))))
                (if (and child-indent (> child-indent indent))
                    (multiple-value-bind (value remaining)
                        (%parse-block lines child-indent file)
                      (setf lines remaining)
                      (push (cons key value) pairs))
                    (push (cons key nil) pairs)))))))
    (values (nreverse pairs) lines)))

(defun %parse-sequence (lines indent file)
  (let ((items '()))
    (loop
      (let ((line (first lines)))
        (when (or (null line) (< (fm-line-indent line) indent)) (return))
        (let ((text (fm-line-text line)))
          (unless (and (>= (length text) 2) (string= "- " (subseq text 0 2)))
            (return))
          (pop lines)
          (let* ((rest (string-trim '(#\Space #\Tab) (subseq text 2)))
                 (entry-indent (+ indent 2)))
            (multiple-value-bind (key value) (%key-and-rest rest (fm-line-number line) file)
              (cond
                ;; "- key: value" starts a map; continuation lines are indented under it
                (key
                 (let ((pairs (list (cons key (if (plusp (length value))
                                                  (%parse-scalar value (fm-line-number line) file)
                                                  nil)))))
                   ;; a key with no inline value may be followed by its own nested block
                   (when (and (zerop (length value))
                              (first lines)
                              (> (fm-line-indent (first lines)) entry-indent))
                     (multiple-value-bind (v remaining)
                         (%parse-block lines (fm-line-indent (first lines)) file)
                       (setf lines remaining)
                       (setf (cdr (first pairs)) v)))
                   (loop while (and (first lines)
                                    (= (fm-line-indent (first lines)) entry-indent)
                                    (not (and (>= (length (fm-line-text (first lines))) 2)
                                              (string= "- " (subseq (fm-line-text (first lines)) 0 2)))))
                         do (multiple-value-bind (more remaining)
                                (%parse-mapping lines entry-indent file)
                              (setf lines remaining)
                              (setf pairs (append pairs more))))
                   (push pairs items)))
                (t (push (%parse-scalar rest (fm-line-number line) file) items))))))))
    (values (nreverse items) lines)))

(defun parse-front-matter-data (text &key file)
  "TEXT (the front-matter block, without delimiters) as an alist."
  (let ((lines (%join-flow-lines (%scan-lines text file) file)))
    (if (null lines)
        '()
        (values (%parse-block lines (fm-line-indent (first lines)) file)))))

;;; --- the typed core, and `extra' (pre-publication issue 359 Q1: answer B) ------------------------

(defparameter +core-keys+ '("title" "date" "slug" "tags" "draft" "publish-at")
  "The keys klio types. Everything else goes to `extra', named so a reader can see where the
engine's knowledge of a document stops.")

(defstruct (content-meta (:constructor %make-content-meta))
  (title nil) (date nil) (slug nil) (tags '()) (draft nil) (publish-at nil)
  (extra '() :type list)
  (warnings '() :type list))

(defun %as-list (value)
  (cond ((null value) '())
        ((listp value) value)
        (t (list value))))

(defun parse-front-matter (text &key file known-extra)
  "Parse TEXT into a CONTENT-META.

KNOWN-EXTRA names keys a SITE expects in `extra'. Anything outside the core and outside that
list is reported as a warning naming the file and the key -- once per key, at load. A typo'd
`tgs:' is otherwise a tag that never appears, with nothing anywhere saying so. The warnings
are returned rather than signalled so the loader can report every file's problems together
instead of stopping at the first."
  (let* ((data (parse-front-matter-data text :file file))
         (meta (%make-content-meta))
         (warnings '()))
    (loop for (key . value) in data
          do (cond
               ((string= key "title") (setf (content-meta-title meta) value))
               ((string= key "date") (setf (content-meta-date meta) value))
               ((string= key "slug") (setf (content-meta-slug meta) value))
               ((string= key "tags") (setf (content-meta-tags meta) (%as-list value)))
               ((string= key "draft") (setf (content-meta-draft meta) (eq value t)))
               ((string= key "publish-at") (setf (content-meta-publish-at meta) value))
               (t
                (push (cons key value) (content-meta-extra meta))
                (unless (member key known-extra :test #'string=)
                  (push (format nil "~@[~A: ~]unknown front-matter key `~A'" file key)
                        warnings)))))
    (setf (content-meta-extra meta) (nreverse (content-meta-extra meta))
          (content-meta-warnings meta) (nreverse warnings))
    meta))

(defun extra (meta key)
  "The value of KEY in META's `extra', or NIL. Nested values come back as nested alists."
  (cdr (assoc key (content-meta-extra meta) :test #'string=)))
