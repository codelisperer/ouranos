;;;; backend.lisp --- the typed neutral store protocol (Coalton core).
;;;;
;;;; What a store IS, typed and IO-free: the BACKEND (SQLite for zero-ops local dev;
;;;; PostgreSQL over the wire protocol for prod; XTDB 2 rides PG wire later), its
;;;; connection config, MIGRATIONs, and the pure logic over them. The effectful
;;;; connect / exec / query / run-migrations shell lives in CL (mnemosyne/conn) over
;;;; CL-DBI -- NO IO here. This is the vocabulary everything else is checked against.

(cl:in-package #:mnemosyne/backend)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- TLS ---------------------------------------------------------------
  ;;;
  ;;; Three vocabularies name the same five intents and NONE of them agree, which is
  ;;; exactly the kind of boundary a type is for. libpq (what a DATABASE_URL carries)
  ;;; says `disable/allow/prefer/require/verify-ca/verify-full`; cl-postgres (the driver
  ;;; underneath CL-DBI) says `:no/:try/:require/:yes/:full`; and the two DISAGREE about
  ;;; what the middle ones mean. Read cl-postgres' own `open-database` docstring:
  ;;;
  ;;;   :require uses provided ssl certificate with no verification.
  ;;;   :yes only verifies that the server cert is issued by a trusted CA,
  ;;;   but does not verify the server hostname.
  ;;;
  ;;; So `:yes` VERIFIES and `:require` does not -- the opposite of what the names
  ;;; suggest, and the difference between encrypted and authenticated. Decoding that
  ;;; once, here, is the whole point; a caller who has to remember it will get it wrong.
  (define-type Ssl-Mode
    "How a Postgres connection negotiates TLS, as intent rather than as any one driver's
spelling.

  SSL-DISABLED     never encrypt.
  SSL-PREFERRED    encrypt if the server offers it; plaintext otherwise. No guarantee.
  SSL-REQUIRED     encrypted, but the certificate is NOT checked -- so it defends
                   against passive eavesdropping and NOT against an active
                   man-in-the-middle. This is what `?sslmode=require` in a managed
                   provider's URL asks for.
  SSL-VERIFY-CA    encrypted, and the certificate must be issued by a trusted CA.
  SSL-VERIFY-FULL  encrypted, CA-checked, AND the hostname must match."
    Ssl-Disabled
    Ssl-Preferred
    Ssl-Required
    Ssl-Verify-Ca
    Ssl-Verify-Full)

  (declare ssl-mode-name (Ssl-Mode -> String))
  (define (ssl-mode-name m)
    "The libpq `sslmode` spelling -- what a URL carries and what an operator recognises.
Round-trips with PARSE-SSL-MODE."
    (match m
      ((Ssl-Disabled) "disable")
      ((Ssl-Preferred) "prefer")
      ((Ssl-Required) "require")
      ((Ssl-Verify-Ca) "verify-ca")
      ((Ssl-Verify-Full) "verify-full")))

  (declare ssl-mode-driver-name (Ssl-Mode -> String))
  (define (ssl-mode-driver-name m)
    "The cl-postgres `use-ssl` keyword, lowercased -- the CL shell interns it. This is the
mapping the header comment above is about, and `verify-ca` -> `yes` is the surprising one."
    (match m
      ((Ssl-Disabled) "no")
      ((Ssl-Preferred) "try")
      ((Ssl-Required) "require")
      ((Ssl-Verify-Ca) "yes")
      ((Ssl-Verify-Full) "full")))

  (declare ssl-mode-guaranteed? (Ssl-Mode -> Boolean))
  (define (ssl-mode-guaranteed? m)
    "Does this mode PROMISE encryption? False for SSL-PREFERRED, whose whole contract is
that it may quietly not encrypt -- which is why the CL shell may degrade it when no TLS
library is loaded, and must never do so for the others."
    (match m
      ((Ssl-Disabled) False)
      ((Ssl-Preferred) False)
      (_ True)))

  (declare parse-ssl-mode (String -> (Optional Ssl-Mode)))
  (define (parse-ssl-mode s)
    "Decode a libpq `sslmode` token. S must already be lowercased and trimmed -- case
folding is the CL shell's job, so this stays a total function over a closed vocabulary.

`allow` and `prefer` both become SSL-PREFERRED: libpq distinguishes them only by which
of plaintext/TLS it tries FIRST, and cl-postgres offers no such distinction, so
pretending to honour it would be a lie in the type."
    (cond
      ((== s "disable") (Some Ssl-Disabled))
      ((== s "allow") (Some Ssl-Preferred))
      ((== s "prefer") (Some Ssl-Preferred))
      ((== s "require") (Some Ssl-Required))
      ((== s "verify-ca") (Some Ssl-Verify-Ca))
      ((== s "verify-full") (Some Ssl-Verify-Full))
      (True None)))

  (declare parse-ssl-mode-or-full (String -> Ssl-Mode))
  (define (parse-ssl-mode-or-full s)
    "PARSE-SSL-MODE, resolving an unreadable token to SSL-VERIFY-FULL.

FAIL CLOSED, and deliberately: this is a security token, so the case we cannot read must
end in a connection that refuses rather than one that quietly runs in the clear. Callers
that can report a better error should check SSL-MODE-KNOWN? first -- the URL parser
does -- which is what keeps this fallback unreachable in practice.

Monomorphic on purpose: it is how the CL shell obtains an SSL-MODE at all, since
unwrapping an Optional from CL is exactly the awkward boundary the house style avoids."
    (match (parse-ssl-mode s)
      ((Some m) m)
      ((None) Ssl-Verify-Full)))

  (declare ssl-mode-known? (String -> Boolean))
  (define (ssl-mode-known? s)
    "Is S a libpq sslmode spelling PARSE-SSL-MODE accepts? The CL-callable half: the shell
checks this and signals its own condition, rather than unwrapping an Optional from CL."
    (match (parse-ssl-mode s)
      ((Some _) True)
      ((None) False)))

  ;;; --- Backends ----------------------------------------------------------
  (define-type Pg-Config
    "A PostgreSQL connection over the wire protocol: host, port, database, user,
password, and how TLS is negotiated. The CL shell builds it from the environment
(.env via cons) or from a DATABASE_URL (mnemosyne/url).

The password is a SECRET rather than a String because Coalton generates a printer that
renders every field, so a String here was printed in full by anything that printed the
config -- most damagingly an unhandled condition's backtrace, which is written to a
deploy log exactly when a deployment is going wrong (pre-publication issue 209). Nothing had to be wrong for
that to happen. AION/SECRET/TYPES:REVEAL is the single, greppable way back to plaintext,
and MNEMOSYNE/CONN:CONNECT is the one place in this framework that calls it."
    (Pg-Config String UFix String String sec:Secret Ssl-Mode))

  (declare pg-host (Pg-Config -> String))
  (define (pg-host c) (match c ((Pg-Config h _ _ _ _ _) h)))
  (declare pg-port (Pg-Config -> UFix))
  (define (pg-port c) (match c ((Pg-Config _ p _ _ _ _) p)))
  (declare pg-database (Pg-Config -> String))
  (define (pg-database c) (match c ((Pg-Config _ _ d _ _ _) d)))
  (declare pg-user (Pg-Config -> String))
  (define (pg-user c) (match c ((Pg-Config _ _ _ u _ _) u)))
  (declare pg-password (Pg-Config -> sec:Secret))
  (define (pg-password c) (match c ((Pg-Config _ _ _ _ pw _) pw)))
  (declare pg-ssl-mode (Pg-Config -> Ssl-Mode))
  (define (pg-ssl-mode c) (match c ((Pg-Config _ _ _ _ _ s) s)))

  (define-type Backend
    "Which store, and how to reach it. SQLITE holds a file path (or \":memory:\") for
zero-ops local dev; POSTGRES holds a wire connection config for prod."
    (Sqlite String)
    (Postgres Pg-Config))

  (declare backend-name (Backend -> String))
  (define (backend-name b)
    "A stable short name for logging / dispatch."
    (match b
      ((Sqlite _) "sqlite")
      ((Postgres _) "postgres")))

  (declare schema-migrations-ddl (Backend -> String))
  (define (schema-migrations-ddl b)
    "Idempotent DDL for the migration-tracking table. The timestamp type differs by
backend; the id/PK shape does not."
    (let ((ts (match b
                ((Sqlite _) "TEXT")
                ((Postgres _) "TIMESTAMPTZ"))))
      (<> "CREATE TABLE IF NOT EXISTS schema_migrations (id TEXT PRIMARY KEY, applied_at "
          (<> ts " NOT NULL DEFAULT CURRENT_TIMESTAMP)"))))

  ;;; CL-facing boundary: the CL/CL-DBI shell builds a BACKEND from CL scalars
  ;;; (MAKE-SQLITE / MAKE-POSTGRES) and reads its fields back via total accessors.
  ;;; A wrong-variant read returns a harmless default -- the shell branches on
  ;;; BACKEND-NAME first, so those defaults are never actually consumed.
  (declare make-sqlite (String -> Backend))
  (define (make-sqlite path) (Sqlite path))

  (declare make-postgres (String * UFix * String * String * String -> Backend))
  (define (make-postgres host port database user password)
    "A Postgres backend with TLS DISABLED.

The arity is unchanged deliberately: this is public API that hyperion/session-db and
hyperion/auth-db already reach, and adding a required argument would break every caller
to change a default they never stated. It keeps today's behaviour -- plaintext -- and
that is the honest reading of a constructor whose caller named a host and a password by
hand and said nothing about transport. The DEPLOYED path is a URL, and
MNEMOSYNE/URL:BACKEND-FROM-URL defaults to `prefer` there, matching libpq.

Reach for MAKE-POSTGRES-WITH-SSL to say otherwise."
    (Postgres (Pg-Config host port database user (sec:make-secret password) Ssl-Disabled)))

  (declare make-postgres-with-ssl (String * UFix * String * String * String * String
                                   -> Backend))
  (define (make-postgres-with-ssl host port database user password sslmode)
    "MAKE-POSTGRES, plus an explicit SSLMODE given as a libpq spelling
(\"disable\" / \"allow\" / \"prefer\" / \"require\" / \"verify-ca\" / \"verify-full\",
lowercase).

An UNRECOGNISED spelling yields SSL-VERIFY-FULL, not a default and not an error: this is
a security token, so the unreadable case fails CLOSED and loudly at connect time rather
than opening a plaintext connection nobody asked for. Callers should reject it earlier --
SSL-MODE-KNOWN? is the check, and the CL shell signals INVALID-DATABASE-URL -- which is
what makes this branch unreachable in practice."
    (Postgres (Pg-Config host port database user (sec:make-secret password)
                         (parse-ssl-mode-or-full sslmode))))

  (declare sqlite-path (Backend -> String))
  (define (sqlite-path b) (match b ((Sqlite p) p) ((Postgres _) "")))

  (declare backend-pg-host (Backend -> String))
  (define (backend-pg-host b) (match b ((Postgres c) (pg-host c)) ((Sqlite _) "")))
  (declare backend-pg-port (Backend -> UFix))
  (define (backend-pg-port b) (match b ((Postgres c) (pg-port c)) ((Sqlite _) 0)))
  (declare backend-pg-database (Backend -> String))
  (define (backend-pg-database b) (match b ((Postgres c) (pg-database c)) ((Sqlite _) "")))
  (declare backend-pg-user (Backend -> String))
  (define (backend-pg-user b) (match b ((Postgres c) (pg-user c)) ((Sqlite _) "")))
  (declare backend-pg-password (Backend -> sec:Secret))
  (define (backend-pg-password b)
    "The password as a SECRET -- REVEAL is the disclosure point, and a caller who only
wants to LOG which database was reached should use BACKEND-PG-HOST / -DATABASE / -USER,
none of which are redacted. A SQLite backend has no password and answers with an empty
secret rather than an empty String, so the return type stays total and unrevealing."
    (match b ((Postgres c) (pg-password c)) ((Sqlite _) (sec:make-secret ""))))
  (declare backend-pg-ssl-mode (Backend -> String))
  (define (backend-pg-ssl-mode b)
    "The libpq spelling of B's TLS mode, for logging and for error messages an operator
has to act on. A SQLite backend has no transport to secure and reports \"disable\"."
    (match b
      ((Postgres c) (ssl-mode-name (pg-ssl-mode c)))
      ((Sqlite _) "disable")))
  (declare backend-pg-ssl-driver (Backend -> String))
  (define (backend-pg-ssl-driver b)
    "The cl-postgres `use-ssl` keyword name for B -- what MNEMOSYNE/CONN interns and
passes to the driver."
    (match b
      ((Postgres c) (ssl-mode-driver-name (pg-ssl-mode c)))
      ((Sqlite _) "no")))
  (declare backend-pg-ssl-guaranteed? (Backend -> Boolean))
  (define (backend-pg-ssl-guaranteed? b)
    "Does B PROMISE an encrypted connection? The CL shell asks before deciding whether a
missing TLS library is a warning or a hard failure."
    (match b
      ((Postgres c) (ssl-mode-guaranteed? (pg-ssl-mode c)))
      ((Sqlite _) False)))

  ;;; --- Migrations --------------------------------------------------------
  (define-type Migration
    "One reversible schema change: a sortable ID (e.g. \"20260722__create_users\"), a
human description, and the up/down SQL. Pure data -- the CL shell runs it."
    (Migration String String String String))

  (declare migration-id (Migration -> String))
  (define (migration-id m) (match m ((Migration i _ _ _) i)))
  (declare migration-description (Migration -> String))
  (define (migration-description m) (match m ((Migration _ d _ _) d)))
  (declare migration-up (Migration -> String))
  (define (migration-up m) (match m ((Migration _ _ u _) u)))
  (declare migration-down (Migration -> String))
  (define (migration-down m) (match m ((Migration _ _ _ d) d)))

  ;; CL-facing constructor: the app/runner builds Migration values from CL scalars.
  (declare make-migration (String * String * String * String -> Migration))
  (define (make-migration id description up down) (Migration id description up down))

  (define-type Direction
    "Which way a migration runs."
    Up Down)

  (declare direction-name (Direction -> String))
  (define (direction-name d)
    (match d
      ((Up) "up")
      ((Down) "down")))

  ;;; --- Pure migration logic ---------------------------------------------
  (declare applied? (String * (List String) -> Boolean))
  (define (applied? id ids)
    "Is migration ID among the already-applied IDS?"
    (match ids
      ((Nil) False)
      ((Cons x xs) (if (== x id) True (applied? id xs)))))

  (declare pending ((List Migration) * (List String) -> (List Migration)))
  (define (pending all applied-ids)
    "The migrations in ALL whose id is not in APPLIED-IDS, order preserved -- exactly
what `run-migrations` (CL) applies, in sequence."
    (filter (fn (m) (not (applied? (migration-id m) applied-ids))) all)))
