;;;; parse.lisp --- SQL string -> query data (the inverse of mnemosyne/query:sql).
;;;;
;;;; For when you know the SQL but not how to spell it in the data form: PARSE takes a SQL
;;;; string (over the subset SQL emits -- SELECT / INSERT / UPDATE / DELETE, the predicate
;;;; grammar, joins, aliases, function calls / aggregates, subqueries, RETURNING, and
;;;; ON CONFLICT upserts) and returns the query plist. Literals in the SQL become values.
;;;; Round-trips with SQL: (sql (parse s) :inline t) reproduces S; (parse (sql q :inline t))
;;;; reproduces Q. A tiny hand-written tokenizer + recursive-descent parser -- no external
;;;; dep, no macro. Genuinely unsupported constructs signal an error rather than mis-parse;
;;;; reach them via (:raw ...).

(in-package #:mnemosyne/query)

;;; --- tokenizer ------------------------------------------------------------
(defparameter +sql-keywords+
  '("SELECT" "FROM" "WHERE" "AND" "OR" "NOT" "LIKE" "IN" "BETWEEN" "IS" "NULL"
    "ORDER" "GROUP" "BY" "HAVING" "LIMIT" "OFFSET" "INSERT" "INTO" "VALUES"
    "UPDATE" "SET" "DELETE" "ASC" "DESC"
    "JOIN" "INNER" "LEFT" "RIGHT" "FULL" "CROSS" "OUTER" "ON" "AS" "EXISTS"
    "DISTINCT" "RETURNING" "CONFLICT" "DO" "NOTHING"))

;; Function/aggregate names that parse back to operator form (mirror of +fn-ops+ in query.lisp).
(defparameter +fn-op-names+
  '("COUNT" "SUM" "AVG" "MIN" "MAX" "COALESCE" "LOWER" "UPPER" "LENGTH" "ABS" "ROUND"))

(defun %word-char-p (c) (or (alphanumericp c) (char= c #\_) (char= c #\.)))

(defun %tokenize (s)
  "SQL string S -> a list of tokens: (:kw \"SELECT\") (:id \"users\") (:str \"a@x\")
(:num 10) (:op \"=\") (:lp) (:rp) (:comma) (:star)."
  (let ((toks '()) (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((c (char s i)))
        (cond
          ((member c '(#\Space #\Tab #\Newline #\Return)) (incf i))
          ((char= c #\')                              ; string literal, '' escapes '
           (incf i)
           (let ((buf (make-string-output-stream)))
             (loop
               (when (>= i n) (error "mnemosyne/query:parse: unterminated string literal"))
               (let ((ch (char s i)))
                 (cond ((and (char= ch #\') (< (1+ i) n) (char= (char s (1+ i)) #\'))
                        (write-char #\' buf) (incf i 2))
                       ((char= ch #\') (incf i) (return))
                       (t (write-char ch buf) (incf i)))))
             (push (list :str (get-output-stream-string buf)) toks)))
          ((char= c #\() (push '(:lp) toks) (incf i))
          ((char= c #\)) (push '(:rp) toks) (incf i))
          ((char= c #\,) (push '(:comma) toks) (incf i))
          ((char= c #\*) (push '(:star) toks) (incf i))
          ((member c '(#\= #\< #\> #\!))
           (let ((two (and (< (1+ i) n) (subseq s i (+ i 2)))))
             (if (and two (member two '("<=" ">=" "<>" "!=") :test #'string=))
                 (progn (push (list :op two) toks) (incf i 2))
                 (progn (push (list :op (string c)) toks) (incf i)))))
          ((or (digit-char-p c)
               (and (char= c #\-) (< (1+ i) n) (digit-char-p (char s (1+ i)))))
           (let ((start i))
             (when (char= c #\-) (incf i))
             (loop while (and (< i n) (or (digit-char-p (char s i)) (char= (char s i) #\.)))
                   do (incf i))
             (push (list :num (let ((*read-eval* nil)) (read-from-string (subseq s start i)))) toks)))
          ((%word-char-p c)
           (let ((start i))
             (loop while (and (< i n) (%word-char-p (char s i))) do (incf i))
             (let* ((w (subseq s start i)) (up (string-upcase w)))
               (push (if (member up +sql-keywords+ :test #'string=)
                         (list :kw up)
                         (list :id (string-downcase w)))
                     toks))))
          (t (error "mnemosyne/query:parse: unexpected character ~C" c)))))
    (nreverse toks)))

;;; --- recursive-descent parser (over a dynamic token list) -----------------
(defvar *toks*)
;; *TOKS* is the parser's position in one statement, bound by PARSE for that one call, and it
;; is DELIBERATELY NOT CARRIED across a thread boundary nor registered with aion/dynamic
;; (#158): PARSE never starts a thread, and a thread started elsewhere during a parse has no
;; business reading another call's token stream.
(defun %peek () (car *toks*))
(defun %peek-type () (car (%peek)))
(defun %peek2 () (cadr *toks*))
(defun %advance () (pop *toks*))
(defun %kw-p (kw) (let ((tk (%peek))) (and tk (eq (car tk) :kw) (string= (second tk) kw))))
(defun %peek2-kw (kw) (let ((tk (%peek2))) (and tk (eq (car tk) :kw) (string= (second tk) kw))))
(defun %opt-kw (kw) (when (%kw-p kw) (%advance) t))
(defun %eat-kw (kw)
  (if (%kw-p kw) (%advance) (error "mnemosyne/query:parse: expected ~A, got ~S" kw (%peek))))
(defun %eat (type)
  (if (eq (%peek-type) type) (%advance)
      (error "mnemosyne/query:parse: expected ~A, got ~S" type (%peek))))
(defun %eat-eq ()
  (let ((tk (%peek)))
    (if (and tk (eq (car tk) :op) (string= (second tk) "=")) (%advance)
        (error "mnemosyne/query:parse: expected =, got ~S" tk))))
(defun %id-kw () (intern (string-upcase (second (%eat :id))) :keyword))
(defun %op->kw (s)
  (cond ((string= s "=") :=) ((string= s "<>") :<>) ((string= s "!=") :!=)
        ((string= s "<") :<) ((string= s ">") :>) ((string= s "<=") :<=)
        ((string= s ">=") :>=) (t (error "mnemosyne/query:parse: unknown operator ~A" s))))

(defun %id->operand (name)
  "An :id string in operand position: a plain column, or EXCLUDED.col in an upsert SET
(the tokenizer keeps \"excluded.col\" whole because '.' is a word char)."
  (let ((low (string-downcase name)))
    (if (and (>= (length low) 9) (string= (subseq low 0 9) "excluded."))
        (list :excluded (intern (string-upcase (subseq name 9)) :keyword))
        (intern (string-upcase name) :keyword))))

(defun %p-funcall (name)
  "Parse NAME( ... ) after NAME (a raw id string). A known aggregate/function name -> the
operator form (:count ...); otherwise (:call \"name\" ...). COUNT(DISTINCT x) -> (:count
(:distinct x)); f(*) keeps :* as the argument."
  (%eat :lp)
  (let ((distinct (%opt-kw "DISTINCT")) (args '()))
    (cond ((eq (%peek-type) :star) (%advance) (setf args (list :*)))
          ((eq (%peek-type) :rp))                       ; no args
          (t (setf args (list (%p-operand)))
             (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-operand) args))
             (setf args (nreverse args))))
    (%eat :rp)
    (when distinct (setf args (list (cons :distinct args))))
    (let ((up (string-upcase name)))
      (if (member up +fn-op-names+ :test #'string=)
          (cons (intern up :keyword) args)
          (list* :call name args)))))

(defun %p-operand ()
  "A column, literal value, function call, or a parenthesized subquery, in expression
position."
  (cond
    ((and (eq (%peek-type) :lp) (%peek2-kw "SELECT"))   ; ( SELECT ... ) subquery
     (%advance) (prog1 (%p-select) (%eat :rp)))
    ((eq (%peek-type) :id)
     (let ((tok (%advance)))
       (if (eq (%peek-type) :lp) (%p-funcall (second tok)) (%id->operand (second tok)))))
    ((eq (%peek-type) :str) (second (%advance)))
    ((eq (%peek-type) :num) (second (%advance)))
    (t (error "mnemosyne/query:parse: expected a column or value, got ~S" (%peek)))))

(defun %p-predicate ()
  (cond
    ((%kw-p "EXISTS") (%advance) (%eat :lp) (prog1 (list :exists (%p-select)) (%eat :rp)))
    ((and (eq (%peek-type) :lp) (not (%peek2-kw "SELECT")))   ; grouped predicate
     (%advance) (prog1 (%p-expr) (%eat :rp)))
    (t
     (let ((lhs (%p-operand)))       ; column | funcall | scalar subquery
       (cond
         ((eq (%peek-type) :op) (list (%op->kw (second (%advance))) lhs (%p-operand)))
         ((%kw-p "LIKE") (%advance) (list :like lhs (%p-operand)))
         ((%kw-p "IN") (%advance) (%eat :lp)
          (if (%kw-p "SELECT")
              (prog1 (list :in lhs (%p-select)) (%eat :rp))          ; IN (SELECT ...)
              (let ((vals (list (%p-operand))))                      ; IN (?, ?, ...)
                (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-operand) vals))
                (%eat :rp) (list :in lhs (nreverse vals)))))
         ((%kw-p "BETWEEN") (%advance)
          (let ((lo (%p-operand))) (%eat-kw "AND") (list :between lhs lo (%p-operand))))
         ((%kw-p "IS") (%advance)
          (if (%opt-kw "NOT") (progn (%eat-kw "NULL") (list :is-not-null lhs))
              (progn (%eat-kw "NULL") (list :is-null lhs))))
         (t (error "mnemosyne/query:parse: expected a predicate after ~S" lhs)))))))

(defun %p-unary ()
  (if (%kw-p "NOT") (progn (%advance) (list :not (%p-unary))) (%p-predicate)))

(defun %p-and ()
  (let ((left (%p-unary)))
    (if (%kw-p "AND")
        (let ((parts (list left)))
          (loop while (%kw-p "AND") do (%advance) (push (%p-unary) parts))
          (cons :and (nreverse parts)))
        left)))

(defun %p-or ()
  (let ((left (%p-and)))
    (if (%kw-p "OR")
        (let ((parts (list left)))
          (loop while (%kw-p "OR") do (%advance) (push (%p-and) parts))
          (cons :or (nreverse parts)))
        left)))

(defun %p-expr () (%p-or))

(defun %p-idlist ()
  (let ((ids (list (%id-kw))))
    (loop while (eq (%peek-type) :comma) do (%advance) (push (%id-kw) ids))
    (nreverse ids)))

(defun %p-select-item ()
  "A projection: *, a column, a function call, optionally AS-aliased -> (:as expr alias)."
  (if (eq (%peek-type) :star)
      (progn (%advance) :*)
      (let ((expr (%p-operand)))
        (cond ((%opt-kw "AS") (list :as expr (%id-kw)))
              ((eq (%peek-type) :id) (list :as expr (%id-kw)))   ; alias without AS
              (t expr)))))

(defun %p-select-list ()
  (let ((items (list (%p-select-item))))
    (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-select-item) items))
    (nreverse items)))

(defun %p-from-item ()
  "A table or subquery, optionally [AS]-aliased -> (:as source alias)."
  (let ((src (if (and (eq (%peek-type) :lp) (%peek2-kw "SELECT"))
                 (progn (%advance) (prog1 (%p-select) (%eat :rp)))
                 (%id-kw))))
    (cond ((%opt-kw "AS") (list :as src (%id-kw)))
          ((eq (%peek-type) :id) (list :as src (%id-kw)))
          (t src))))

(defun %p-from-list ()
  (let ((items (list (%p-from-item))))
    (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-from-item) items))
    (nreverse items)))

(defun %p-join-kind ()
  "The kind of the next JOIN (consuming any INNER/LEFT/… prefix), or NIL if none is next.
The bare-JOIN case is left for %p-joins to eat."
  (cond ((%kw-p "JOIN") :inner)                                    ; do not advance; eaten below
        ((%kw-p "INNER") (%advance) :inner)
        ((%kw-p "LEFT")  (%advance) (%opt-kw "OUTER") :left)
        ((%kw-p "RIGHT") (%advance) (%opt-kw "OUTER") :right)
        ((%kw-p "FULL")  (%advance) (%opt-kw "OUTER") :full)
        ((%kw-p "CROSS") (%advance) :cross)
        (t nil)))

(defun %p-joins ()
  (let ((joins '()))
    (loop for kind = (%p-join-kind) while kind do
      (%eat-kw "JOIN")
      (let ((src (%p-from-item)))
        (if (eq kind :cross)
            (push (list kind src) joins)
            (progn (%eat-kw "ON") (push (list kind src (%p-expr)) joins)))))
    (nreverse joins)))

(defun %p-order ()
  (flet ((spec ()
           (let ((col (%id-kw)))
             (cond ((%kw-p "DESC") (%advance) (list col :desc))
                   ((%kw-p "ASC")  (%advance) (list col :asc))
                   (t col)))))
    (let ((specs (list (spec))))
      (loop while (eq (%peek-type) :comma) do (%advance) (push (spec) specs))
      (nreverse specs))))

(defun %p-returning (q)
  "Attach a trailing RETURNING clause (idlist or *) to DML query Q, if present."
  (if (%kw-p "RETURNING")
      (progn (%advance)
             (nconc q (list :returning (if (eq (%peek-type) :star)
                                           (progn (%advance) '(:*))
                                           (%p-idlist)))))
      q))

(defun %p-select ()
  (%eat-kw "SELECT")
  (let ((q (list :select (%p-select-list))))
    (%eat-kw "FROM") (setf q (nconc q (list :from (%p-from-list))))
    (let ((joins (%p-joins))) (when joins (setf q (nconc q (list :join joins)))))
    (when (%kw-p "WHERE")  (%advance) (setf q (nconc q (list :where (%p-expr)))))
    (when (%kw-p "GROUP")  (%advance) (%eat-kw "BY") (setf q (nconc q (list :group-by (%p-idlist)))))
    (when (%kw-p "HAVING") (%advance) (setf q (nconc q (list :having (%p-expr)))))
    (when (%kw-p "ORDER")  (%advance) (%eat-kw "BY") (setf q (nconc q (list :order-by (%p-order)))))
    (when (%kw-p "LIMIT")  (%advance) (setf q (nconc q (list :limit (second (%eat :num))))))
    (when (%kw-p "OFFSET") (%advance) (setf q (nconc q (list :offset (second (%eat :num))))))
    q))

(defun %p-value-row (cols)
  (%eat :lp)
  (let ((vals (list (%p-operand))))
    (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-operand) vals))
    (%eat :rp)
    (loop for c in cols for v in (nreverse vals) append (list c v))))

(defun %p-on-conflict (q)
  "Parse an ON CONFLICT (cols) DO NOTHING|UPDATE SET ... upsert tail onto INSERT query Q."
  (when (%kw-p "ON")
    (%advance) (%eat-kw "CONFLICT") (%eat :lp)
    (let ((cols (%p-idlist)))
      (%eat :rp)
      (setf q (nconc q (list :on-conflict cols)))
      (%eat-kw "DO")
      (if (%kw-p "NOTHING")
          (progn (%advance) (setf q (nconc q (list :do-nothing t))))
          (progn (%eat-kw "UPDATE") (%eat-kw "SET")
                 (let ((set '()))
                   (loop (let ((col (%id-kw))) (%eat-eq) (push col set) (push (%p-operand) set))
                         (if (eq (%peek-type) :comma) (%advance) (return)))
                   (setf q (nconc q (list :do-update (nreverse set)))))))))
  q)

(defun %p-insert ()
  (%eat-kw "INSERT") (%eat-kw "INTO")
  (let ((table (%id-kw)))
    (%eat :lp)
    (let ((cols (%p-idlist)))
      (%eat :rp) (%eat-kw "VALUES")
      (let ((rows (list (%p-value-row cols))))
        (loop while (eq (%peek-type) :comma) do (%advance) (push (%p-value-row cols) rows))
        (let ((q (list :insert-into table :values (nreverse rows))))
          (setf q (%p-on-conflict q))
          (%p-returning q))))))

(defun %p-update ()
  (%eat-kw "UPDATE")
  (let ((table (%id-kw)))
    (%eat-kw "SET")
    (let ((set '()))
      (loop
        (let ((col (%id-kw))) (%eat-eq) (push col set) (push (%p-operand) set))
        (if (eq (%peek-type) :comma) (%advance) (return)))
      (let ((q (list :update table :set (nreverse set))))
        (when (%kw-p "WHERE") (%advance) (setf q (nconc q (list :where (%p-expr)))))
        (%p-returning q)))))

(defun %p-delete ()
  (%eat-kw "DELETE") (%eat-kw "FROM")
  (let ((q (list :delete-from (%id-kw))))
    (when (%kw-p "WHERE") (%advance) (setf q (nconc q (list :where (%p-expr)))))
    (%p-returning q)))

(defun parse (sql-string)
  "Parse SQL-STRING (over mnemosyne/query's supported subset) into a query plist -- the
inverse of SQL. Literals become values. Unsupported constructs signal an error rather than
mis-parse. Round-trips: (sql (parse s) :inline t) reproduces S."
  (let ((*toks* (%tokenize sql-string)))
    (let ((result
            (cond ((%kw-p "SELECT") (%p-select))
                  ((%kw-p "INSERT") (%p-insert))
                  ((%kw-p "UPDATE") (%p-update))
                  ((%kw-p "DELETE") (%p-delete))
                  (t (error "mnemosyne/query:parse: unsupported/empty statement at ~S" (%peek))))))
      (when *toks*
        (error "mnemosyne/query:parse: unexpected trailing tokens ~S" *toks*))
      result)))
