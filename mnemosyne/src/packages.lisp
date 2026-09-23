;;;; packages.lisp --- Mnemosyne package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. As the data layer
;;;; grows, expect packages like:
;;;;   mnemosyne/schema   -- typed schema / entity definitions (Coalton)
;;;;   mnemosyne/query    -- the query DSL (Coalton-typed where it can be)
;;;;   mnemosyne/conn     -- connection + pool behind a neutral backend protocol
;;;;   mnemosyne/migrate  -- migrations (bitemporal-aware)
;;;;   mnemosyne/backend/postgres -- the PostgreSQL-wire backend (Postmodern);
;;;;                                 XTDB 2 speaks PG wire, so it rides the same
;;;;                                 protocol.
;;;; Common-core approach: typed core in Coalton, effectful shell in CL. No IO in
;;;; the Coalton core.

(cl:defpackage #:mnemosyne
  (:use #:cl)
  (:documentation
   "Mnemosyne: the bitemporal data layer (Ecto-like) for the codelisperer stack.")
  (:export #:version))

;;; --- backend: the typed neutral store protocol (Coalton core) ------------
(cl:defpackage #:mnemosyne/backend
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:sec #:aion/secret/types))
  (:documentation
   "The typed, IO-free core of the neutral store protocol: what a BACKEND is (SQLite
    for zero-ops local dev; PostgreSQL over the wire for prod -- XTDB 2 rides PG wire
    later), its connection config, MIGRATIONs, and the pure logic over them (which
    are pending; the schema_migrations DDL). No IO -- the effectful connect / exec /
    query / run-migrations shell lives in CL over CL-DBI.")
  (:export
   #:Backend #:Sqlite #:Postgres
   #:Pg-Config #:pg-host #:pg-port #:pg-database #:pg-user #:pg-password #:pg-ssl-mode
   #:backend-name #:schema-migrations-ddl
   ;; TLS: intent, decoded once from libpq's vocabulary and mapped once to the driver's
   #:Ssl-Mode #:Ssl-Disabled #:Ssl-Preferred #:Ssl-Required #:Ssl-Verify-Ca
   #:Ssl-Verify-Full
   #:ssl-mode-name #:ssl-mode-driver-name #:ssl-mode-guaranteed? #:parse-ssl-mode
   #:parse-ssl-mode-or-full #:ssl-mode-known?
   ;; CL-facing boundary (constructors + total field accessors)
   #:make-sqlite #:make-postgres #:make-postgres-with-ssl #:sqlite-path
   #:backend-pg-host #:backend-pg-port #:backend-pg-database #:backend-pg-user
   #:backend-pg-password
   #:backend-pg-ssl-mode #:backend-pg-ssl-driver #:backend-pg-ssl-guaranteed?
   #:Migration #:make-migration
   #:migration-id #:migration-description #:migration-up #:migration-down
   #:Direction #:Up #:Down #:direction-name
   #:pending))

;;; --- field: the typed field-type vocabulary (Coalton core) ---------------
(cl:defpackage #:mnemosyne/field-shell
  (:use #:cl)
  (:documentation
   "The effectful half of the field-type vocabulary: a refusal from the typed core becomes a
    condition here (ADR-0001). Separate from mnemosyne/field because that package is Coalton
    and must stay IO-free, and because all three DDL callers need the same decision made the
    same way -- three copies is how three drift.")
  (:export #:unknown-dialect #:unknown-dialect-name
           #:unsupported-field-type #:unsupported-field-type-field
           #:unsupported-field-type-type #:unsupported-field-type-backend
           #:unsupported-field-type-support
           #:dialect-for #:dialect-name-of #:dialect= #:+dialects+ #:+dialect-names+
           #:column-sql #:field-type-supported-p))

(cl:defpackage #:mnemosyne/field
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typed, IO-free field-type vocabulary a schema column declares: a Field-Type maps to
    a SQL column type per dialect (DDL) and names the cast the CL shell applies. No IO --
    definition, casting, and validation are the effectful CL shell (schema / changeset).")
  (:export
   #:Field-Type
   #:FT-String #:FT-Text #:FT-Integer #:FT-Float #:FT-Boolean #:FT-Uuid #:FT-Timestamp #:FT-Date
   #:field-type-name #:field-type-sql #:field-type-from #:field-type-width
   #:FT-Vector
   #:Dialect #:D-Sqlite #:D-Postgres #:D-Xtdb #:dialect-name #:dialect-from #:dialect-known? #:dialect-required
   #:Sql-Type #:Native #:Emulated #:Unsupported #:sql-type-tag #:sql-type-text
   #:field-type-support))

;;; --- entity: typed entity metadata -- the DTO trait + pure touch (Coalton) --
(cl:defpackage #:mnemosyne/entity
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typesafe half of the MPP db/core port: entity METADATA (id, version, timestamps,
    audit) as a compile-time-checked DTO typeclass instead of Clojure's assoc-onto-any-map.
    TOUCH is pure (create vs update); the fresh identity arrives from the CL shell as a
    STAMP (mnemosyne/id). No IO here.")
  (:export
   #:Stamp #:make-stamp #:stamp-uuid #:stamp-vid #:stamp-instant
   #:Meta #:make-meta
   #:meta-id #:meta-vid #:meta-created #:meta-modified #:meta-created-by #:meta-modified-by
   #:DTO #:get-meta #:with-meta #:touch))

;;; --- id: time-ordered UUID/vid generation + touch! (effectful CL shell) ---
(cl:defpackage #:mnemosyne/id
  (:use #:cl)
  (:local-nicknames (#:entity #:mnemosyne/entity)
                    (#:clock #:aion/clock))
  ;; NEW-ID, NEXT-VID and VID->INSTANT are aion/clock's symbols, imported and re-exported
  ;; rather than wrapped. The clock moved to aion (pre-publication issue 96) because it is a floor primitive and
  ;; not a persistence concern, but MNEMOSYNE/ID:NEW-ID is called from hyperion/auth-db,
  ;; from the blob store and from two example apps -- so the seam stays exactly where it
  ;; was and those call sites do not move. Re-export, not a forwarding DEFUN: this way
  ;; MNEMOSYNE/ID:NEW-ID and AION/CLOCK:NEW-ID are the SAME symbol, so the two can never
  ;; drift apart and nobody has to wonder which one they are looking at.
  (:import-from #:aion/clock #:new-id #:next-vid #:vid->instant)
  (:documentation
   "Entity stamping over aion/clock's time-ordered identities.

    NEW-ID / NEXT-VID / VID->INSTANT are re-exported from AION/CLOCK, which owns the
    monotonic Gregorian-100ns clock and the v6 assembly. What lives HERE is the part that
    is genuinely about rows: NEW-STAMP, which packages an identity as a mnemosyne/entity
    STAMP, and TOUCH!, the dynamic hash-table analog of Clojure's touch! -- including the
    _id/vid/utc-time-* column names, which are mnemosyne's convention and nobody else's.
    The typed counterpart is mnemosyne/entity:touch.")
  (:export #:new-id #:new-stamp #:next-vid #:vid->instant #:touch!))

;;; --- conn: connect / exec / query / transaction over CL-DBI (effectful CL) --
;;; --- url: one connection string -> a typed Backend (CL shell) ------------
(cl:defpackage #:mnemosyne/url
  (:use #:cl)
  (:local-nicknames (#:be #:mnemosyne/backend))
  (:documentation
   "DATABASE_URL -> a typed BACKEND. Every PaaS (DigitalOcean, Heroku, Render, Fly,
    Railway, Neon, Supabase) hands an application ONE string instead of five values, so
    without this every deployed app writes the same parser -- and the parts that are
    easy to get wrong are the parts that fail at 3am against a real database: a
    percent-encoded password, a bracketed IPv6 host, an absent port, and the `sslmode`
    that says whether TLS is required.

    A bad URL signals INVALID-DATABASE-URL at STARTUP rather than yielding a Backend
    that fails later at connect time.")
  (:export #:backend-from-url #:invalid-database-url #:invalid-database-url-url
           #:invalid-database-url-reason))

(cl:defpackage #:mnemosyne/param
  (:use #:cl)
  (:documentation
   "What a bound value MEANS, and how each backend must be told it (pre-publication issue 165). CL NIL is
    false, the empty list and \"no value\" at once; SQL needs those distinct, and the
    drivers disagreed -- Postgres rendered NIL as the literal `false` (a hard error on
    numerics, silent corruption in text) while SQLite already stored SQL NULL. The
    vocabulary is three values, not two: NIL/:NULL mean SQL NULL, :TRUE/T mean true,
    :FALSE means false. Sentinels never reach a driver -- both refuse them -- so they are
    translated here, which is why this is a boundary rather than a Postgres patch.")
  (:export #:to-driver #:to-driver-params
           #:from-driver #:from-driver-row #:from-driver-rows
   #:row-value #:row-keys #:unknown-column #:unknown-column-key #:unknown-column-available
           #:null-value-p #:true-value-p #:false-value-p))

(cl:defpackage #:mnemosyne/conn
  (:use #:cl)
  (:local-nicknames (#:be #:mnemosyne/backend)
                    (#:param #:mnemosyne/param)
                    (#:sec #:aion/secret)
                    (#:log #:aion/log))
  (:documentation
   "The effectful CL shell: open a CL-DBI connection for a typed BACKEND (Postgres
    over the wire via cl-postgres; SQLite for local dev), run statements and queries,
    and scope transactions. Recoverable failure is a DB-ERROR condition wrapping the
    driver's, not a return code. Start/stop-symmetric CONNECT/DISCONNECT + a
    WITH-CONNECTION macro (no globals -- a future Atropos component wraps them).")
  (:export #:connect #:disconnect #:with-connection
           #:exec #:query #:with-transaction
           #:db-error #:db-error-message #:db-error-cause))

;;; --- migrate: the migration runner (CL, over backend + conn) -------------
(cl:defpackage #:mnemosyne/migrate
  (:use #:cl)
  (:local-nicknames (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn)
                    (#:log #:aion/log))
  (:documentation
   "The migration runner: ensure the schema_migrations tracking table, compute which
    of a set of typed MIGRATIONs are pending, and apply their up-SQL in order -- each in
    a transaction, recording its id -- idempotently. ROLLBACK runs down-SQL newest-first.
    Migrations are Lisp-defined data (mnemosyne/backend:make-migration); no framework.")
  (:export #:migrate #:rollback #:pending #:applied-ids
           ;; extensions are a deployment fact, not a schema one (pre-publication issue 258)
           #:require-extension #:extension-available-p #:extension-present-p
           #:extension-unavailable #:extension-unavailable-name
           #:extension-unavailable-reason #:extension-unavailable-detail))

;;; --- query: HoneySQL-style data-driven SQL generation (CL) ---------------
(cl:defpackage #:mnemosyne/query
  (:use #:cl)
  (:local-nicknames (#:fld #:mnemosyne/field)
                    (#:fldsh #:mnemosyne/field-shell))
  (:documentation
   "HoneySQL-style data-driven SQL generation: a query plist (with s-expr predicates)
    compiles to a parameterized SQL string + ordered params (values always bound, never
    interpolated -- injection-safe). SELECT/INSERT/UPDATE/DELETE + a small operator set;
    dialect-aware (?-params for sqlite/postgres, verified; :xtdb is the seam for XTDB 2's
    $N params + no-DDL + temporal SELECT). SQL returns (values sql params); FETCH / RUN
    compile then run via mnemosyne/conn.")
  ;; +DIALECTS+ MOVED to MNEMOSYNE/FIELD-SHELL (pre-publication issue 432, ADR-0003). It was a second list of
  ;; the same three dialects, spelled as keywords where ddl and schema spelled them as
  ;; strings, and the two vocabularies could not disagree loudly -- only by one module
  ;; taking a branch meant for the other.
  (:export #:sql #:fetch #:run #:parse #:*dialect*
           #:+vector-distance-ops+ #:vector-distance-opclass
           #:*warn-unindexed-vector-distance* #:unindexed-vector-distance
           #:unindexed-vector-distance-operator #:unindexed-vector-distance-opclass))

;;; --- schema: Ecto-style schema definitions + DDL generation (CL) ----------
(cl:defpackage #:mnemosyne/derived
  (:use #:cl)
  (:documentation
   "When a value derived from a row's text has gone stale (ADR-0002). A CONTENT FINGERPRINT
    over exactly the inputs to the derived value, computed in the CL shell with the caller's
    own hash and stored in an ordinary column, so finding stale rows compares a stored value
    against a bind parameter on every backend. A version stamp is a different question --
    `did this ROW change' -- and mnemosyne/id:touch! already answers it.")
  (:export #:content-fingerprint #:frame-inputs #:derived-stale-p
           #:fingerprint-column #:deriver-column
           #:no-fingerprint-hash))

(cl:defpackage #:mnemosyne/schema
  (:use #:cl)
  (:local-nicknames (#:fld #:mnemosyne/field)
                    (#:fldsh #:mnemosyne/field-shell))
  (:documentation
   "Ecto-style schema definitions: DEFSCHEMA names a table and its typed FIELDs (types from
    the Coalton mnemosyne/field core). One source of truth for two readers: SCHEMA-DDL (a
    migration's up-SQL) and changeset casting/validation. A registry maps schema name ->
    SCHEMA. DDL stays raw SQL in migrations, but its shape is derived here, not hand-written.")
  (:export
   #:defschema #:schema #:field #:make-field #:make-schema #:field-type-for
   #:register-schema #:find-schema #:schema-field #:primary-key #:schema-ddl
   #:schema-name #:schema-table #:schema-fields
   #:field-name #:field-type #:field-type-name #:field-required #:field-primary #:field-default
   ;; a derived value's inputs, and the companion columns the convention adds (ADR-0002)
   #:field-derived-from #:derived-fields #:derived-inputs #:expand-derived))

;;; --- changeset: cast + validate external data, then bridge to queries (CL) -
;;; --- DDL as data: indexes / drop / alter, rendered per dialect (CL) -------
(cl:defpackage #:mnemosyne/ddl
  (:use #:cl)
  (:local-nicknames (#:fld #:mnemosyne/field)
                    (#:fldsh #:mnemosyne/field-shell))
  (:documentation
   "DDL as DATA, the same way the query DSL treats DML: a form like
    (:create-index :name :idx_a :on :users :columns (:email) :unique t) renders to SQL for
    a dialect. Closes the gap that forced migrations to hand-write CREATE INDEX / DROP
    TABLE / ALTER TABLE as raw strings. Generation is OPTIONAL -- raw SQL keeps working
    everywhere and stays the escape hatch. Dialect differences (SQLite's limited ALTER
    TABLE, no CASCADE; XTDB 2's absence of DDL) signal UNSUPPORTED-DDL at render time. Pure
    -- no IO; CONN:EXEC runs the result.")
  (:export #:ddl #:ddl-statements
           #:+index-methods+ #:+vector-opclasses+
           #:unsupported-ddl #:unsupported-ddl-dialect #:unsupported-ddl-operation
           #:unsupported-ddl-detail))

;;; --- introspect: what the TABLE is, vs what the DEFSCHEMA says (CL) -------
(cl:defpackage #:mnemosyne/introspect
  (:use #:cl)
  (:local-nicknames (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn)
                    (#:schema #:mnemosyne/schema)
                    (#:fldsh #:mnemosyne/field-shell))
  (:documentation
   "Does the live table still match its DEFSCHEMA? (pre-publication issue 144)

    SCHEMA-DDL derives CREATE TABLE from a MUTABLE definition for an IMMUTABLE, applied
    migration, so editing a defschema rewrites history for every database that has not
    caught up. The model that survives is: the defschema is the PRESENT, the migration
    list is HISTORY, and a fresh database replays history to ARRIVE at the present. This
    package measures that last claim instead of asserting it -- TABLE-COLUMNS reads the
    catalog, SCHEMA-DIFF compares it to the definition as DATA, VERIFY-SCHEMA signals
    SCHEMA-DRIFT, and DRIFT-DDL turns the difference back into mnemosyne/ddl forms so the
    reconciling ALTER is derived rather than hand-written into a NEW migration.

    Effectful CL -- reading a catalog is IO -- but SCHEMA-DIFF and DRIFT-DDL are pure and
    take the columns as an argument, so the comparison is testable with no database.")
  (:export
   #:table-columns #:table-exists-p
   #:column #:column-name #:column-sql-type #:column-required #:column-primary
   #:column-default
   #:schema-diff #:diff-table #:report-drift
   #:drift #:drift-table #:drift-schema-name #:drift-dialect #:drift-table-present
   #:drift-missing #:drift-extra #:drift-mismatched #:drift-clean-p
   #:verify-schema #:schema-drift #:schema-drift-drift
   #:drift-ddl))

(cl:defpackage #:mnemosyne/changeset
  (:use #:cl)
  (:documentation
   "Ecto-style changesets: CAST a bag of raw params (form/JSON) against a schema, taking only
    permitted fields (safe mass-assignment) and casting each to its type; then thread an
    immutable pipeline of VALIDATE-* accumulating errors. When valid, the CHANGES compile
    straight into a mnemosyne/query INSERT/UPDATE (TO-INSERT / TO-UPDATE / INSERT! / UPDATE!),
    so raw params never reach SQL uncast. CHANGESET-INVALID signals only at the edge.")
  (:export
   #:cast #:changeset #:changeset-valid-p #:changeset-changes #:changeset-errors #:changeset-schema
   #:get-change #:apply-changes #:add-error
   #:validate-required #:validate-change #:validate-format #:validate-length #:validate-number
   #:validate-inclusion #:validate-exclusion
   #:to-insert #:to-update #:insert! #:update!
   #:changeset-invalid #:changeset-invalid-changeset))
