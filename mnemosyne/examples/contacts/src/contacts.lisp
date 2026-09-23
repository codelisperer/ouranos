;;;; contacts.lisp --- a console demo of the mnemosyne migration lifecycle.
;;;;
;;;; Shows migrations end to end over a SQLite file: on startup it applies pending
;;;; migrations, then drops into a tiny command loop -- migrate / rollback / status, plus
;;;; add / list contacts (each stamped with mnemosyne/id:touch!, queried with the data-driven
;;;; query builder). `cons run` starts it; `cons bin` dumps a native binary. Scaffolded by
;;;; `cons init contacts --template cli`, then pointed at mnemosyne.

(cl:in-package #:mnemosyne/examples/contacts)

(defparameter +version+ "0.0.0" "contacts version.")
(defun version () +version+)

(defparameter *db* "contacts.db" "SQLite file, relative to the working directory.")
(defun backend () (be:make-sqlite *db*))

;;; --- the schema (its CREATE TABLE feeds migration #1) ---------------------
(schema:defschema contact (:table "contacts")
  (:_id        :string  :primary t)
  (:vid        :integer)
  (:name       :string  :required t)
  (:email      :string)
  (:role       :string)
  (:created_at :timestamp)
  (:updated_at :timestamp)
  (:created_by :string)
  (:updated_by :string))

(defparameter *migrations*
  (list
   (be:make-migration
    "20260725_001_create_contacts" "create the contacts table"
    (schema:schema-ddl (schema:find-schema 'contact) :dialect "sqlite")   ; derived, not hand-written
    "DROP TABLE IF EXISTS contacts")
   (be:make-migration
    "20260725_002_index_name" "index contacts by name"
    "CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts (name)"
    "DROP INDEX IF EXISTS idx_contacts_name"))
  "The ordered migration set (Lisp-defined data; ids sort, so id order = apply order).")

;;; --- colored console output (ANSI; NO_COLOR respected) --------------------
(defparameter *color* t)
(defparameter +esc+ (code-char 27))
(defun paint (code s) (if *color* (format nil "~C[~Am~A~C[0m" +esc+ code s +esc+) s))
(defun say  (code fmt args) (format t "  ~A~%" (paint code (apply #'format nil fmt args))))
(defun ok   (fmt &rest a) (say "32" fmt a))      ; green
(defun info (fmt &rest a) (say "2"  fmt a))       ; dim
(defun attn (fmt &rest a) (say "33" fmt a))       ; yellow
(defun oops (fmt &rest a) (say "31" fmt a))       ; red
(defun head (s) (format t "~%~A~%" (paint "1;36" s)))   ; bold cyan

;;; --- helpers --------------------------------------------------------------
(defun short-id (id) (if (>= (length id) 8) (subseq id 0 8) id))

(defun rest-of-line (line)
  "LINE with its first whitespace-delimited token removed, trimmed.

The command loop tokenises on whitespace, which is right for `migrate' and `list' and wrong
for anything carrying free text. Rather than teach the loop about quoting, a command that
wants its own argument syntax is handed the remainder and parses it -- see `parse-add-line'."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line))
         (sp (position-if (lambda (ch) (member ch '(#\Space #\Tab))) trimmed)))
    (if sp (string-trim '(#\Space #\Tab) (subseq trimmed sp)) "")))

(defun stamp->columns (e)
  "Map the `id:touch!'-stamped hash-table E to its contacts columns -- THE METADATA ONLY.

This used to carry the domain fields too, and that is the half that moved: `name', `email'
and `role' are console input, so they now arrive through the changeset (see `contact-changeset')
rather than being copied through a mapper. What is left is the part a hand-written mapper is
still needed for, and it is #93's whole subject:

  :utc-time-created  ->  created_at     different names, no mechanical rule
  :utc-time-modified ->  updated_at     ditto
  :created-by        ->  created_by     hyphen vs underscore
  :modified-by       ->  updated_by     different name AND separator

THIS FUNCTION EXISTING IS THE SIGNAL THAT #93 HAS NOT LANDED. When `touch!' and `defschema'
agree on names, or the framework owns the translation, this goes away and the stamp can be
cast like anything else -- at which point `cs:insert!' becomes reachable here and this
example can use it. Until then the insert below is assembled by hand, deliberately and
visibly, rather than pretending the join exists."
  (list :_id (gethash :_id e) :vid (gethash :vid e)
        :created_at (gethash :utc-time-created e) :updated_at (gethash :utc-time-modified e)
        :created_by (gethash :created-by e) :updated_by (gethash :modified-by e)))

(defun col (row key)
  "Value of column KEY (keyword) from a fetched ROW plist, case-insensitively, as a string."
  (let ((name (symbol-name key)))
    (or (loop for (k v) on row by #'cddr
              when (and (symbolp k) (string-equal (symbol-name k) name))
                do (return (and v (princ-to-string v))))
        "")))

(defun ensure-migrations-table (c)
  (conn:exec c (be:schema-migrations-ddl (backend))))

;;; --- commands -------------------------------------------------------------
(defun cmd-migrate (c)
  (let ((applied (migrate:migrate (backend) c *migrations*)))
    (if applied
        (progn (ok "applied ~D migration~:P" (length applied))
               (dolist (m applied) (info "+ ~A" m)))
        (info "already up to date"))))

(defun cmd-rollback (c)
  (let ((rolled (migrate:rollback (backend) c *migrations* :steps 1)))
    (if rolled
        (dolist (m rolled) (attn "rolled back ~A" m))
        (info "nothing to roll back"))))

(defun cmd-status (c)
  (ensure-migrations-table c)
  (head "migrations")
  (let ((applied (migrate:applied-ids c))
        (pending (mapcar #'be:migration-id (migrate:pending c *migrations*))))
    (if applied (dolist (m applied) (ok "applied  ~A" m)) (info "none applied"))
    (if pending (dolist (m pending) (attn "pending  ~A" m)) (info "none pending"))))

;;; --- adding a contact: the path the doctrine actually mandates (#94) -----
;;;
;;; The root AGENTS.md says "external input flows cast -> validate -> insert!", and until
;;; this commit no example in the tree did that -- including this one, which SHIPS THREE
;;; FILES telling the reader to (its AGENTS.md, .cursor/rules, and the mnemosyne-data
;;; skill) beside a raw :insert-into. A reader following the examples wrote uncast inserts;
;;; a reader following the docs found no worked reference.
;;;
;;; WHAT THE OLD CODE DID INSTEAD OF VALIDATING, because it is the more interesting half:
;;; it constrained its own input so that nothing needed validating. Names were restricted to
;;; a single token ("use 'seed' for samples"), and the seed data was hyphenated to match --
;;; "Ada-Lovelace", "Alan-Turing". The absence of a validation path was paid for in the
;;; demo's data, which is the kind of workaround that looks like a design choice afterwards.
;;; Both go away here: `add' now splits on commas, so names are names.

(defparameter +add-allowed+ '(:name :email :role)
  "The ONLY fields console input may set -- `cast''s allowed list, and the whole point of it.

Safe mass-assignment: a field absent from this list can never move from params into the
changeset, whatever the params contain. That matters less for three positional console
arguments than for a web form, which is exactly why an example should show it -- the reader
copying this into an HTTP handler inherits the guard rather than having to think of it.

Note what is NOT here: `_id', `vid', and the timestamps. Those are the framework's to stamp,
and a caller must not be able to supply them.")

(defun plausible-email-p (s)
  "A deliberately weak check: one @, something either side, no spaces.

Weak ON PURPOSE. Validating email addresses properly is a famous way to reject real ones,
and the example's job is to show WHERE validation attaches, not to be an authority on
RFC 5322. Anything stricter here would teach the wrong lesson twice over."
  (let ((at (position #\@ s)))
    (and at (> at 0) (< at (1- (length s)))
         (not (find #\Space s))
         (not (position #\@ s :start (1+ at))))))

(defun contact-changeset (params)
  "cast + validate PARAMS against the contact schema. Returns a changeset.

PURE: no connection, no console, no clock -- which is what lets the suite exercise the
rules without a database. That separation is the point of the changeset being a value
rather than a side effect.

PARAMS may be a plist, an alist or a hash-table; `cast' accepts all three, which is the
thing #94 assumed was missing and which has in fact been true for some time."
  (let ((cs (cs:cast 'contact params +add-allowed+)))
    (setf cs (cs:validate-required cs '(:name)))
    (setf cs (cs:validate-length cs :name :max 120))
    ;; Absent fields pass `validate-change', so an omitted email is fine and a malformed
    ;; one is not. That is the behaviour the old code could not express: it coerced a
    ;; missing email to "" and then had nothing to say about a wrong one.
    (setf cs (cs:validate-format cs :email #'plausible-email-p
                                 :message "does not look like an email address"))
    cs))

(defun %split-on (char string)
  (mapcar (lambda (s) (string-trim '(#\Space #\Tab) s))
          (uiop:split-string string :separator (list char))))

(defun parse-add-line (rest-of-line)
  "The `add' arguments as a params plist: `name, email, role', comma separated.

Commas rather than spaces so a name can be a name. The old command split on whitespace,
which is why it demanded a single token and why the seed data was hyphenated."
  (destructuring-bind (&optional name email role) (%split-on #\, rest-of-line)
    (let ((params '()))
      ;; Absent and empty are DIFFERENT here, and the changeset relies on it: a field that
      ;; is not in params is simply not cast, while "" is a value that fails
      ;; `validate-required'. The old code flattened both to "".
      (when (and role  (plusp (length role)))  (setf params (list* :role role params)))
      (when (and email (plusp (length email))) (setf params (list* :email email params)))
      ;; A blank name is ABSENT, not a name. `%split-on' over "   " yields ("") after
      ;; trimming, so without this `add' with no arguments produced (:name "") and the
      ;; changeset refused it with "name: can't be blank" -- a true message answering the
      ;; wrong question, when what the user needs is the usage line. Caught by
      ;; `an-empty-add-line-yields-no-params'.
      (when (and name (plusp (length name))) (setf params (list* :name name params)))
      params)))

(defun report-changeset-errors (cs)
  (dolist (err (cs:changeset-errors cs))
    (oops "~(~A~): ~A" (car err) (cdr err))))

(defun cmd-add (c rest-of-line)
  (let ((params (parse-add-line rest-of-line)))
    (if (null params)
        (oops "usage: add <name>[, <email>[, <role>]]     e.g.  add Ada Lovelace, ada@analytical.engine, Mathematician")
        (let ((cs (contact-changeset params)))
          (if (not (cs:changeset-valid-p cs))
              ;; The refusal is the feature. Nothing is stamped, nothing is inserted, and
              ;; the user is told which field and why -- from `changeset-errors', not from
              ;; a message this function invented.
              (report-changeset-errors cs)
              (let ((e (make-hash-table)))
                (id:touch! e "console")              ; stamp _id / vid / timestamps / audit
                (handler-case
                    (progn
                      ;; ASSEMBLED BY HAND, AND VISIBLY SO. `cs:insert!' writes exactly
                      ;; `changeset-changes' and a changeset cannot be added to after
                      ;; `cast', so there is no way to carry the stamp through it while
                      ;; `touch!' and `defschema' disagree about names. That is #93, and
                      ;; when it lands these two lines become (cs:insert! cs c).
                      (query:run c (list :insert-into "contacts"
                                         :values (list (append (stamp->columns e)
                                                               (cs:apply-changes cs))))
                                 :dialect :sqlite)
                      (ok "added ~A  (id ~A, vid ~A)"
                          (cs:get-change cs :name) (short-id (gethash :_id e)) (gethash :vid e)))
                  (conn:db-error (err)
                    (oops "~A  (run 'migrate' first?)" (conn:db-error-message err))))))))))

(defun cmd-seed (c)
  ;; REAL NAMES. These were hyphenated -- "Ada-Lovelace" -- because `add' split on
  ;; whitespace and demanded a single token, so the demo data was shaped by a workaround
  ;; for a missing validation path (#94). Both are gone.
  (dolist (r '(("Ada Lovelace" "ada@analytical.engine" "Mathematician")
               ("Alan Turing" "alan@bombe.uk" "Cryptanalyst")
               ("Grace Hopper" "grace@cobol.mil" "Rear Admiral")
               ("Barbara-Liskov" "barbara@clu.mit" "Professor")))
    (cmd-add c r)))

(defun cmd-list (c args)
  (ensure-migrations-table c)
  (let* ((term (first args))
         (q (append (list :select '(:name :email :role :vid) :from '("contacts"))
                    (when term (list :where (list :like :name (format nil "%~A%" term))))
                    (list :order-by '(:vid))))
         (rows (handler-case (query:fetch c q :dialect :sqlite)
                 (conn:db-error (err)
                   (oops "~A  (run 'migrate' first?)" (conn:db-error-message err)) nil))))
    (head (if term (format nil "contacts matching ~S" term) "contacts"))
    (if rows
        (dolist (r rows)
          (format t "  ~24A ~28A ~A~%"
                  (paint "1" (col r :name)) (paint "2" (col r :email)) (paint "36" (col r :role))))
        (info "no contacts"))))

;;; --- the loop -------------------------------------------------------------
(defun banner ()
  (head "mnemosyne · contacts")
  (info "a console demo of migrations + query over SQLite (~A)" *db*)
  (info "commands: migrate · rollback · status · seed · add <name>[, <email>[, <role>]] · list [term] · help · quit"))

(defun prompt () (format t "~%~A " (paint "1;33" "contacts>")) (finish-output))

(defun run-console (&key (color t))
  "Start the interactive console: apply pending migrations, then read commands until EOF/quit."
  (let ((*color* color))
    (conn:with-connection (c (backend))
      (banner)
      (head "startup: applying pending migrations")
      (cmd-migrate c)
      (loop
        (prompt)
        (let ((line (read-line *standard-input* nil :eof)))
          (when (eq line :eof) (return))
          (let* ((toks (remove "" (uiop:split-string
                                   (string-trim '(#\Space #\Tab #\Return) line)
                                   :separator '(#\Space #\Tab))
                               :test #'string=))
                 (cmd (first toks)) (args (rest toks)))
            (cond
              ((null cmd) nil)
              ((member cmd '("quit" "q" "exit") :test #'string-equal) (return))
              ((string-equal cmd "help")     (banner))
              ((string-equal cmd "migrate")  (cmd-migrate c))
              ((string-equal cmd "rollback") (cmd-rollback c))
              ((string-equal cmd "status")   (cmd-status c))
              ((string-equal cmd "seed")     (cmd-seed c))
              ;; THE RAW REMAINDER, not `args'. `add' parses its own arguments on commas
              ;; so a name can contain spaces; handing it the whitespace tokens is what
              ;; forced single-token names (#94).
              ((string-equal cmd "add")      (cmd-add c (rest-of-line line)))
              ((string-equal cmd "list")     (cmd-list c args))
              (t (oops "unknown command: ~A  (try 'help')" cmd))))))
      (head "bye")))
  (values))

(defun main ()
  "Entry point: `cons run` (in-process) or the dumped bin/contacts."
  (run-console :color (not (uiop:getenvp "NO_COLOR")))
  (uiop:quit 0))
