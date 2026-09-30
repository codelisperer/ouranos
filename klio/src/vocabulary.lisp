;;;; vocabulary.lisp --- a controlled list in one content file, and the check on references to it (#353).
;;;;
;;;; THE CASE. The personal site keeps a controlled list of skills in one content file,
;;;; grouped: `groups', a list of maps, each with a `name' and a `skills' list of labels. Other
;;;; pages will refer to entries by label, in a `skills' list on the page or on one of its
;;;; bullets, and the CV generator matches job descriptions against the same list. A reference
;;;; to a label that is not in the list is a mistake nobody would see: the page renders, the
;;;; label just matches nothing. So it is a LOAD FAILURE, naming the file that made the
;;;; reference and the file that holds the list, and it goes through ADR-0001's one rule like
;;;; any other failure: at boot the site refuses to start, at reload it keeps the old tree.
;;;;
;;;; A SITE DECLARES A VOCABULARY; the content does not. MAKE-VOCABULARY names the document that
;;;; holds the list, the path to the entries inside that document's `extra', and the paths in
;;;; other documents that refer to it. A path is a list of keys. Where a step lands on a list,
;;;; the rest of the path is followed into every element, so ("groups" "skills") collects the
;;;; skills of every group, and ("bullets" "skills") the skills of every bullet.
;;;;
;;;; LABELS MATCH EXACTLY. The labels include punctuation (C#, C++, .NET), and any normalising
;;;; rule would have to tell those apart; exact matching needs no rule, and an author sees the
;;;; failure and fixes the spelling.
;;;;
;;;; This file works on (key . content-meta) pairs, so it needs nothing from content.lisp, which
;;;; calls it.

(in-package #:klio)

(defstruct (vocabulary (:constructor %make-vocabulary) (:copier nil))
  (name "" :type string :read-only t)
  (source "" :type string :read-only t)
  (entries-path '() :type list :read-only t)
  (reference-paths '() :type list :read-only t))

(defun make-vocabulary (name &key source entries references)
  "A controlled vocabulary called NAME: the labels found at the path ENTRIES in the `extra' of
the document whose key is SOURCE, checked against every label found at any of the paths in
REFERENCES in every other document. A path is a list of keys; see the file header.

  (make-vocabulary \"skills\" :source \"skills\" :entries '(\"groups\" \"skills\")
                            :references '((\"skills\") (\"bullets\" \"skills\")))"
  (flet ((path-p (p) (and (consp p) (every #'stringp p))))
    (unless (and (stringp source) (plusp (length source)))
      (error "make-vocabulary ~S: SOURCE must be the key of the document that holds the list, not ~S."
             name source))
    (unless (path-p entries)
      (error "make-vocabulary ~S: ENTRIES must be a path, a non-empty list of keys, not ~S."
             name entries))
    (unless (and (listp references) (every #'path-p references))
      (error "make-vocabulary ~S: REFERENCES must be a list of paths, each a non-empty list of keys, not ~S."
             name references))
    (%make-vocabulary :name name :source source :entries-path (copy-list entries)
                      :reference-paths (mapcar #'copy-list references))))

(defun %sequence-p (value)
  "Whether VALUE is a front-matter sequence rather than a mapping: a list whose elements are
not (key . value) pairs with string keys. See %MAPPING-P in content.lisp for the distinction."
  (and (listp value)
       (notevery (lambda (e) (and (consp e) (stringp (car e)))) value)))

(defun %at-path (value path)
  "The values found by following PATH from VALUE, a mapping, into every element of any list
on the way. Returns a list of the values at the end of PATH."
  (cond ((null path) (list value))
        ((and (consp value) (%sequence-p value))
         (loop for element in value append (%at-path element path)))
        ((consp value)
         (let ((entry (assoc (first path) value :test #'equal)))
           (and entry (%at-path (cdr entry) (rest path)))))
        (t '())))

(defun %labels (values)
  "The strings in VALUES, where a value is a string or a list of strings."
  (loop for v in values
        append (cond ((stringp v) (list v))
                     ((listp v) (remove-if-not #'stringp v))
                     (t '()))))

(defun vocabulary-labels (vocabulary meta)
  "The labels VOCABULARY's entry path finds in META, the source document's front matter."
  (%labels (%at-path (content-meta-extra meta) (vocabulary-entries-path vocabulary))))

(defun %vocabulary-failures (vocabulary pairs)
  "Every failure of VOCABULARY over PAIRS, a list of (key . content-meta), as (file . reason)
conses, and the vocabulary's labels as a second value."
  (let ((source (assoc (vocabulary-source vocabulary) pairs :test #'string=)))
    (if (null source)
        (values (list (cons (vocabulary-source vocabulary)
                            (format nil "the vocabulary `~A' is declared to be in this document, and there is no such document"
                                    (vocabulary-name vocabulary))))
                '())
        (let* ((labels (vocabulary-labels vocabulary (cdr source)))
               (known (let ((set (make-hash-table :test #'equal)))
                        (dolist (l labels set) (setf (gethash l set) t))))
               (failures '()))
          (when (null labels)
            (push (cons (car source)
                        (format nil "the vocabulary `~A' finds no entries at ~{~A~^ > ~} in this document"
                                (vocabulary-name vocabulary) (vocabulary-entries-path vocabulary)))
                  failures))
          (dolist (pair pairs)
            (unless (eq pair source)
              (dolist (path (vocabulary-reference-paths vocabulary))
                (dolist (label (%labels (%at-path (content-meta-extra (cdr pair)) path)))
                  (unless (gethash label known)
                    (push (cons (car pair)
                                (format nil "`~{~A~^ > ~}' refers to ~S, which is not in the vocabulary `~A' in ~A"
                                        path label (vocabulary-name vocabulary) (car source)))
                          failures))))))
          (values (nreverse failures) labels)))))
