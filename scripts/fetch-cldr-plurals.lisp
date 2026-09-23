;;;; fetch-cldr-plurals.lisp --- regenerate the vendored CLDR cardinal plural rules.
;;;;
;;;;     sbcl --script scripts/fetch-cldr-plurals.lisp            # verify the vendored copy
;;;;     sbcl --script scripts/fetch-cldr-plurals.lisp --write     # fetch, verify, regenerate
;;;;
;;;; WHY THIS EXISTS RATHER THAN A HAND-WRITTEN TABLE. Plural agreement is not a property
;;;; of the languages we happen to ship -- it is a property of whatever locale a user
;;;; selects. Hand-writing the families we know about (Slavic, Arabic, Romanian) means the
;;;; table is wrong for the first locale nobody anticipated, and wrong silently: a missing
;;;; rule falls back to `other`, which reads as a translation problem rather than a missing
;;;; rule. Generating all 224 from CLDR costs a few tens of KB -- less than the Bulma
;;;; already vendored -- and cannot drift, because nobody transcribes anything.
;;;;
;;;; WHAT IS GENERATED: an s-expression AST per (locale, category), not Lisp code. The
;;;; runtime evaluator in hyperion/src/plural.lisp walks it. Data rather than code because
;;;; a generator that emits code invites hand-editing the output, which is exactly the
;;;; drift this is meant to prevent.
;;;;
;;;; PINNED like every other vendored artefact in this tree (libuv.pin, ASSETS.pin): a
;;;; CLDR version and a sha256 of the upstream file, checked before anything is written.
;;;; Run with no arguments in CI to assert the vendored copy still matches its pin.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (ql:quickload '(:dexador :com.inuoe.jzon :ironclad) :silent t))

(defpackage #:cldr-plurals (:use #:cl))
(in-package #:cldr-plurals)

;;; THE TREE IS THE CALLER'S, NOT THIS FILE'S (#480). This was
;;; `(pathname-parent-directory-pathname (pathname-directory-pathname *load-truename*))',
;;; so one checkout's copy run from another regenerated the OTHER checkout's vendored rules
;;; and pin -- two writes, both into a tree the operator was not looking at. Same defect as
;;; #450 in check-readme-counts, same resolver.
(defparameter *script* (or *load-truename* *load-pathname*))
(load (merge-pathnames "tree-root.lisp" (uiop:pathname-directory-pathname *script*)))

(defparameter *root* (tree-root:resolve-or-die *script* "fetch-cldr-plurals"))

(defparameter *pin-file* (merge-pathnames "hyperion/src/vendor/PLURALS.pin" *root*))
(defparameter *out-file* (merge-pathnames "hyperion/src/vendor/cldr-plurals.lisp" *root*))

(defparameter *cldr-version* "48.2.1")
(defparameter *expected-sha256*
  "6c0a48e9bcfc25856f90202f703c2c7f89c105d6868f7712a943a6ed2dcbe8f4")
(defparameter *url*
  (format nil "https://raw.githubusercontent.com/unicode-org/cldr-json/~A~
              /cldr-json/cldr-core/supplemental/plurals.json" *cldr-version*))

(defun sha256 (octets)
  (string-downcase (ironclad:byte-array-to-hex-string
                    (ironclad:digest-sequence :sha256 octets))))

;;; --- parsing the CLDR rule syntax -----------------------------------------
;;;
;;; The grammar, from UTS #35, minus the parts cardinal rules never use:
;;;
;;;   condition     = and_condition ('or' and_condition)*
;;;   and_condition = relation ('and' relation)*
;;;   relation      = expr ('=' | '!=') range_list
;;;   expr          = operand ('%' value)?
;;;   range_list    = (range | value) (',' (range | value))*
;;;   range         = value '..' value
;;;
;;; Everything from '@' onward is sample data for documentation and is discarded.
;;;
;;; Note `and` binds tighter than `or`, which is why the split order below is not
;;; arbitrary: splitting on `or` first yields the correct precedence for free.

(defun strip-samples (rule)
  (let ((at (position #\@ rule)))
    (string-trim " " (if at (subseq rule 0 at) rule))))

(defun split-on (needle string)
  "Split STRING on the delimiter NEEDLE (a string), trimming each piece."
  (let ((out '()) (start 0))
    (loop for at = (search needle string :start2 start)
          while at
          do (push (string-trim " " (subseq string start at)) out)
             (setf start (+ at (length needle))))
    (push (string-trim " " (subseq string start)) out)
    (nreverse out)))

(defun parse-range-list (text)
  "`2..4, 7, 9..11` -> ((2 . 4) (7 . 7) (9 . 11)). A bare value is a one-wide range, so
the evaluator has exactly one shape to handle."
  (loop for piece in (split-on "," text)
        for dots = (search ".." piece)
        collect (if dots
                    (cons (parse-integer (subseq piece 0 dots))
                          (parse-integer (subseq piece (+ dots 2))))
                    (let ((v (parse-integer piece)))
                      (cons v v)))))

(defun parse-relation (text)
  "`i % 10 != 12..14` -> (:REL :I 10 :NEQ ((12 . 14)))"
  (let* ((neq (search "!=" text))
         (op (if neq :neq :eq))
         (at (or neq (position #\= text)))
         (lhs (string-trim " " (subseq text 0 at)))
         (rhs (string-trim " " (subseq text (+ at (if neq 2 1)))))
         (pct (position #\% lhs))
         (operand (intern (string-upcase (string-trim " " (if pct (subseq lhs 0 pct) lhs)))
                          :keyword))
         (modulus (and pct (parse-integer (string-trim " " (subseq lhs (1+ pct)))))))
    (list :rel operand modulus op (parse-range-list rhs))))

(defun parse-condition (rule)
  "A whole rule -> (:OR (:AND relation...) ...). An empty rule (the usual `other`) is NIL,
meaning `always` -- the evaluator treats a missing rule and a matching one identically."
  (let ((body (strip-samples rule)))
    (when (plusp (length body))
      (list* :or (mapcar (lambda (conj) (list* :and (mapcar #'parse-relation
                                                            (split-on " and " conj))))
                         (split-on " or " body))))))

;;; --- generation -----------------------------------------------------------

(defun category-from-key (key)
  "`pluralRule-count-few` -> :FEW"
  (let ((at (search "count-" key)))
    (intern (string-upcase (subseq key (+ at 6))) :keyword)))

(defun build-table (json)
  "The whole file -> ((locale (category . ast) ...) ...), locales sorted for a stable diff."
  (let* ((rules (gethash "plurals-type-cardinal" (gethash "supplemental" json)))
         (out '()))
    (maphash (lambda (locale cats)
               (let ((entries '()))
                 (maphash (lambda (k v)
                            (let ((cat (category-from-key k)))
                              ;; `other` is the fallback and never needs a test.
                              (unless (eq cat :other)
                                (push (cons cat (parse-condition v)) entries))))
                          cats)
                 ;; CLDR emits categories in a defined precedence; sort so evaluation
                 ;; order is deterministic and matches it.
                 (push (cons locale
                             (sort entries #'< :key (lambda (e)
                                                      (position (car e)
                                                                '(:zero :one :two :few :many)))))
                       out)))
             rules)
    (sort out #'string< :key #'car)))

(defun write-vendored (table source-sha)
  (with-open-file (s *out-file* :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
    (format s ";;;; cldr-plurals.lisp --- GENERATED. Do not edit.~%")
    (format s ";;;;~%;;;; CLDR ~A, plurals.json sha256 ~A~%" *cldr-version* source-sha)
    (format s ";;;; Regenerate: sbcl --script scripts/fetch-cldr-plurals.lisp --write~%")
    (format s ";;;;~%;;;; ~D locales. Each entry is (locale (category . condition) ...) where a~%"
            (length table))
    (format s ";;;; condition is (:OR (:AND (:REL operand modulus :EQ|:NEQ ((lo . hi) ...)) ...) ...)~%")
    (format s ";;;; and NIL means `always`. Categories are in CLDR precedence order;~%")
    (format s ";;;; `other` is the fallback and carries no test.~%~%")
    (format s "(in-package #:hyperion/plural)~%~%")
    (format s "(defparameter +cldr-plural-rules+~%  '(")
    (loop for (locale . entries) in table
          for first = t then nil
          do (format s "~:[~%    ~;~](~S~{ ~S~})" first locale entries))
    (format s "))~%~%")
    (format s "(defparameter +cldr-version+ ~S)~%" *cldr-version*)))

;;; --- main -----------------------------------------------------------------

(let* ((write-p (member "--write" (rest sb-ext:*posix-argv*) :test #'string=))
       (body (handler-case (dex:get *url* :force-binary t)
               (error (e) (format *error-output* "~&fetch failed: ~A~%" e) (uiop:quit 1))))
       (actual (sha256 body)))
  (format t "~&CLDR ~A~%  url:      ~A~%  sha256:   ~A~%" *cldr-version* *url* actual)
  (unless (string= actual *expected-sha256*)
    (format *error-output*
            "~&sha256 MISMATCH~%  expected ~A~%  got      ~A~%~
             Upstream changed under a pinned tag, or the pin is stale. Do not regenerate~%~
             until you know which.~%" *expected-sha256* actual)
    (uiop:quit 1))
  (format t "  pin:      OK~%")
  (if (not write-p)
      (format t "~&Verified. Pass --write to regenerate the vendored rules.~%")
      (let ((table (build-table (com.inuoe.jzon:parse (sb-ext:octets-to-string body
                                                                     :external-format :utf-8)))))
        (ensure-directories-exist *out-file*)
        (write-vendored table actual)
        (with-open-file (s *pin-file* :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
          (format s "# CLDR cardinal plural rules -- version, checksum, source, licence.~%#~%")
          (format s "# The rules are DATA generated from upstream, never transcribed: a~%")
          (format s "# hand-written table is wrong for the first locale nobody anticipated,~%")
          (format s "# and wrong silently, since a missing rule falls back to `other`.~%#~%")
          (format s "# Regenerate:  sbcl --script scripts/fetch-cldr-plurals.lisp --write~%")
          (format s "# Verify only: sbcl --script scripts/fetch-cldr-plurals.lisp~%#~%")
          (format s "version   ~A~%" *cldr-version*)
          (format s "url       ~A~%" *url*)
          (format s "sha256    ~A~%" actual)
          (format s "locales   ~D~%" (length table))
          (format s "generated hyperion/src/vendor/cldr-plurals.lisp~%")
          (format s "licence   Unicode-3.0 (https://www.unicode.org/license.txt)~%"))
        (format t "~&Wrote ~A (~D locales)~%and ~A~%" *out-file* (length table) *pin-file*))))
