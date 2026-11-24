;;;; probes.lisp --- stored-data probes that read a mnemosyne database (#1028, dokimasia
;;;; ADR-0001, point 2, "Stored data").
;;;;
;;;; An aux system of dokimasia that depends on mnemosyne. It defines probes for :EXPECT-STORED
;;;; steps whose local form reads the app's database through a mnemosyne connection. dokimasia
;;;; runs a probe's local form only against a target that can see the app's store (a process
;;;; target), so against a deployed URL these steps are reported as not run unless the probe
;;;; also has an HTTP form.

(in-package #:dokimasia/mnemosyne)

(defun %invalid (control &rest args)
  (error 'd:invalid-definition :reason (apply #'format nil control args)))

(defun %connection-source (source)
  "The backend or pool SOURCE names: SOURCE itself, or what calling it returns when it is a
function, so an app can name a database that exists only once its target has started."
  (if (or (functionp source) (and (symbolp source) (fboundp source)))
      (funcall source)
      source))

(defun %fetch (source query dialect)
  "The rows QUERY returns from SOURCE's database, each a plist."
  (let ((dialect (or dialect query:*dialect*)))
    (conn:with-connection (c (%connection-source source))
      (query:fetch c query :dialect dialect))))

(defun %column-name (column)
  (string-downcase (string column)))

(defun %where (columns values)
  "A mnemosyne WHERE clause that holds when each of COLUMNS equals the matching one of VALUES."
  (let ((tests (mapcar (lambda (column value) (list := column value)) columns values)))
    (if (rest tests) (cons :and tests) (first tests))))

(defun %describe-match (columns values)
  "\"email = \\\"a@example.com\\\" and plan = \\\"free\\\"\" for COLUMNS and VALUES."
  (format nil "~{~A~^ and ~}"
          (mapcar (lambda (column value) (format nil "~A = ~S" (%column-name column) value))
                  columns values)))

(defun %check-common (name source dialect)
  (unless (or (symbolp name) (stringp name))
    (%invalid "a probe's name is a symbol or a string; got ~S" name))
  (unless source
    (%invalid "the probe ~(~A~) needs a :SOURCE: a mnemosyne backend, a pool, or a function that returns one" name))
  (when dialect
    (handler-case (fldsh:dialect-for dialect)
      (error () (%invalid "the probe ~(~A~): ~S is not a dialect mnemosyne knows" name dialect)))))

(defun %probe-function (source dialect absent query-of describe)
  "The local form of a probe. QUERY-OF builds a query from the step's values, or returns NIL and a
reason when the values cannot be used. The probe passes when the query returns a row, or, when
ABSENT is true, when it returns none. DESCRIBE gives the reason for a failure, from the values and
the rows the query returned."
  (lambda (&rest values)
    (block probe
      (multiple-value-bind (query why) (apply query-of values)
        (unless query
          (return-from probe (values nil why)))
        (let ((rows (handler-case (%fetch source query dialect)
                      (conn:db-error (c)
                        (return-from probe
                          (values nil (format nil "the database refused the probe's query: ~A"
                                              (conn:db-error-message c))))))))
          (if (if absent (null rows) rows)
              t
              (values nil (funcall describe values rows))))))))

;;; --- a row with these values -----------------------------------------------------------

(defparameter +near-rows-shown+ 3
  "How many rows matching only the first column a row probe's failure shows.")

(defun %near-rows (source dialect table match values)
  "The stored values, as text, of up to +NEAR-ROWS-SHOWN+ rows of TABLE whose first MATCH column
holds the first of VALUES, or NIL when there are none or the query fails."
  (let ((rows (ignore-errors
               (%fetch source (list :select match :from (list table)
                                    :where (list := (first match) (first values))
                                    :limit +near-rows-shown+)
                       dialect))))
    (mapcar (lambda (row)
              (format nil "~{~A~^, ~}"
                      (mapcar (lambda (column)
                                (format nil "~A = ~S" (%column-name column)
                                        (param:row-value row column :if-missing nil)))
                              (rest match))))
            rows)))

(defun define-row-probe (name &key source table match absent dialect http)
  "Register the stored-data probe NAME, which checks that TABLE has a row whose MATCH columns
hold the step's values, in order: (:EXPECT-STORED NAME value ...) gives one value for each
column of MATCH. With ABSENT true, it checks that no such row exists instead.

SOURCE is the database: a mnemosyne backend, a pool, or a function of no arguments that returns
one when the step runs, for a database that exists only once the target has started. DIALECT is
the SQL dialect, as MNEMOSYNE/QUERY:FETCH takes it; NIL means MNEMOSYNE/QUERY:*DIALECT* when the
step runs. HTTP is an optional HTTP form, as DOKIMASIA:DEFINE-PROBE takes it.

When no row matches and MATCH has more than one column, the failure also gives the other columns'
stored values in the rows that match the first column, so the report says which value differs."
  (%check-common name source dialect)
  (unless (keywordp table)
    (%invalid "the probe ~(~A~): :TABLE is a keyword naming the table; got ~S" name table))
  (unless (and match (listp match) (every #'keywordp match))
    (%invalid "the probe ~(~A~): :MATCH is a list of keywords naming columns; got ~S" name match))
  (flet ((select (values)
           (list :select match :from (list table) :where (%where match values) :limit 1)))
    ;; Compile one query now, so a table or column name mnemosyne refuses is refused when the
    ;; probe is defined rather than in the middle of a run.
    (handler-case (query:sql (select (mapcar (constantly "x") match))
                             :dialect (or dialect query:*dialect*))
      (error (c) (%invalid "the probe ~(~A~): ~A" name c)))
    (let ((columns (format nil "~{~A~^, ~}" (mapcar #'%column-name match))))
      (d:define-probe
       name
       :http http
       :local (%probe-function
               source dialect absent
               (lambda (&rest values)
                 (if (= (length values) (length match))
                     (select values)
                     (values nil (format nil "it matches ~D column~:P (~A), and the step gave ~D value~:P"
                                         (length match) columns (length values)))))
               (lambda (values rows)
                 (declare (ignore rows))
                 (let ((described (%describe-match match values)))
                   (cond (absent
                          (format nil "~A has a row with ~A, and the step expected none"
                                  (%column-name table) described))
                         ((rest match)
                          (let ((near (%near-rows source dialect table match values)))
                            (format nil "~A has no row with ~A~:[~;; the rows with ~A = ~S have ~{~A~^; ~}~]"
                                    (%column-name table) described
                                    near (%column-name (first match)) (first values) near)))
                         (t (format nil "~A has no row with ~A" (%column-name table) described)))))))))
  name)

;;; --- any query -------------------------------------------------------------------------

(defun define-query-probe (name &key source query absent dialect http)
  "Register the stored-data probe NAME, which runs the mnemosyne query that QUERY, a function,
returns when called with the step's values, and passes when the query returns at least one row.
With ABSENT true, it passes when the query returns none. Use it for what a row probe cannot say,
such as a join or a comparison other than equality.

SOURCE, DIALECT and HTTP are as for DEFINE-ROW-PROBE."
  (%check-common name source dialect)
  (unless (or (functionp query) (and (symbolp query) query (fboundp query)))
    (%invalid "the probe ~(~A~): :QUERY is a function of the step's values that returns a mnemosyne query; got ~S"
              name query))
  (d:define-probe
   name
   :http http
   :local (%probe-function
           source dialect absent
           (lambda (&rest values) (apply query values))
           (lambda (values rows)
             (if absent
                 (format nil "the query for ~{~S~^, ~} returned ~D row~:P, and the step expected none"
                         values (length rows))
                 (format nil "the query for ~{~S~^, ~} returned no row" values)))))
  name)
