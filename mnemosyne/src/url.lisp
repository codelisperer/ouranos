;;;; url.lisp --- one connection string -> a typed Backend (the CL shell).
;;;;
;;;; Every managed Postgres provider configures an application with a single
;;;; DATABASE_URL rather than with five separate values, so an app that cannot read one
;;;; cannot deploy. This turns the string into a BACKEND, or signals.
;;;;
;;;; WHY THIS IS NOT `(quri:uri url)` AND FIVE ACCESSORS, which is what it looks like it
;;;; should be. Measured against quri 0.7.0 before writing this:
;;;;
;;;;   (quri:uri "postgres://user@[::1]:5432/db")
;;;;   => URI ... contains an illegal character #\[ at position 16.
;;;;
;;;; quri parses a bracketed IPv6 host correctly when there is NO userinfo
;;;; ("https://[2001:db8::1]/x" is fine) and rejects the whole URL when userinfo is
;;;; present -- and a DATABASE_URL essentially always has userinfo. It also mangles
;;;; "sqlite://:memory:" into host ":memory", and it accepts "not a url" as a relative
;;;; path with a NIL scheme rather than rejecting it.
;;;;
;;;; So the AUTHORITY is split here, where those cases can be handled, and quri is used
;;;; for the one part it does correctly and that genuinely should not be hand-rolled:
;;;; PERCENT-DECODING. That is not "scan for %" -- a percent-escape may encode one byte
;;;; of a multi-byte UTF-8 sequence, so decoding character-by-character corrupts any
;;;; non-ASCII password, and generated passwords are exactly where this bites.
;;;;
;;;; Splitting an authority, by contrast, is pure ASCII structure with four documented
;;;; rules (below), and it is testable.

(in-package #:mnemosyne/url)

(define-condition invalid-database-url (error)
  ((url    :initarg :url    :initform nil :reader invalid-database-url-url)
   (reason :initarg :reason :reader invalid-database-url-reason))
  (:report
   (lambda (c stream)
     (format stream "mnemosyne: cannot read a database URL: ~A" (invalid-database-url-reason c))
     ;; The URL itself is NEVER printed: it carries the password, and this condition will
     ;; be reported into a log or a crash dump. Naming the fault without leaking the
     ;; credential is the whole reason this is a slot rather than an interpolation.
     (format stream "~%~%Expected one of:~%")
     (format stream "  postgres://USER:PASSWORD@HOST:PORT/DATABASE?sslmode=require~%")
     (format stream "  postgresql://...            (both spellings are accepted)~%")
     (format stream "  sqlite:///path/to/app.db    (or sqlite://:memory:)~%")))
  (:documentation
   "Signalled when a DATABASE_URL cannot be turned into a BACKEND. Deliberately signalled
at STARTUP, by the constructor, rather than returning a Backend that fails later at
connect time -- a malformed URL should stop the process while somebody is watching.

The URL is held in a slot and never printed, because it contains the password."))

(defun %fail (url reason &rest args)
  (error 'invalid-database-url :url url :reason (apply #'format nil reason args)))

(defun %decode (string url what)
  "Percent-decode STRING, or signal. WHAT names the component for the error message."
  (handler-case (quri:url-decode string)
    (error () (%fail url "~A contains a malformed percent-escape" what))))

(defun %split-once (string char)
  "(values BEFORE AFTER) at the FIRST CHAR, or (values STRING nil) if absent."
  (let ((i (position char string)))
    (if i
        (values (subseq string 0 i) (subseq string (1+ i)))
        (values string nil))))

(defun %split-last (string char)
  "(values BEFORE AFTER) at the LAST CHAR, or (values nil STRING) if absent.

The LAST one, for userinfo: a password may legitimately contain an unencoded `@` -- the
spec says it should be encoded, generators do not always encode it, and libpq itself
splits on the last. Splitting on the first turns a working URL into an auth failure whose
cause is invisible."
  (let ((i (position char string :from-end t)))
    (if i
        (values (subseq string 0 i) (subseq string (1+ i)))
        (values nil string))))

(defun %parse-host-port (hostport url)
  "(values HOST PORT-or-NIL) from an authority's host[:port], handling [IPv6].

The bracket rule is the reason this is not (split-once #\\:): an IPv6 literal is full of
colons, so the port is only the colon AFTER the closing bracket."
  (if (and (plusp (length hostport)) (char= (char hostport 0) #\[))
      (let ((close (position #\] hostport)))
        (unless close
          (%fail url "the host opens with `[' but never closes it"))
        (let ((host (subseq hostport 1 close))
              (rest (subseq hostport (1+ close))))
          (cond ((zerop (length rest)) (values host nil))
                ((char= (char rest 0) #\:) (values host (subseq rest 1)))
                (t (%fail url "unexpected text after the bracketed host")))))
      (multiple-value-bind (host port) (%split-last hostport #\:)
        (if host
            (values host port)
            (values port nil)))))     ; no colon: %SPLIT-LAST returns it as AFTER

(defun %parse-port (string url)
  (let ((n (handler-case (parse-integer string)
             (error () (%fail url "the port is not a number")))))
    (unless (<= 1 n 65535)
      (%fail url "the port ~D is outside 1-65535" n))
    n))

(defun %query-value (query name url)
  "The last value of NAME in a k=v&k=v QUERY string, percent-decoded, or NIL.

The LAST, because that is what libpq does with a repeated key -- and a URL carrying
`?sslmode=disable&sslmode=require` must not resolve to the weaker one by accident.

Decoding goes through %DECODE like every other component. It used to pass QURI's
:LENIENT T, which returns a malformed escape UNCHANGED instead of signalling -- so
`sslmode=req%ZZuire` arrived at the known-mode check as the literal string
`req%ZZuire' and was reported as an unknown sslmode. The operator is then told to
choose from a list their value is already on, and the actual fault -- a mangled URL --
is never named. Every component of this URL fails the same way for the same reason."
  (let ((found nil))
    (dolist (pair (uiop:split-string (or query "") :separator "&") found)
      (multiple-value-bind (k v) (%split-once pair #\=)
        (when (and v (string-equal k name))
          (setf found (%decode v url (format nil "the `~A' query parameter" name))))))))

(defun %sqlite-from-url (rest url)
  "A sqlite: URL. REST is everything after the scheme's `//'.

Taken verbatim as a path rather than parsed as an authority, because there is no host in
a SQLite URL and quri's authority rules mangle \":memory:\" into a host of \":memory\".

The path decodes through %DECODE for the same reason the query does, and here the
lenient version was the more dangerous of the two: nothing downstream validates a
filesystem path, so a mangled escape produced no error at all -- it opened (and, being
SQLite, CREATED) a different database file than the operator configured, silently."
  (be:make-sqlite (if (string= rest "") ":memory:" (%decode rest url "the database path"))))

(defun %postgres-from-url (rest url)
  "A postgres:/postgresql: URL. REST is everything after the scheme's `//'."
  (let (authority path query)
    ;; The authority ends at the first `/' or `?'. Doing this before touching userinfo
    ;; keeps a `/' inside an unencoded password from being read as the start of the path.
    (let ((end (or (position-if (lambda (c) (or (char= c #\/) (char= c #\?))) rest)
                   (length rest))))
      (setf authority (subseq rest 0 end))
      (multiple-value-bind (p q) (%split-once (subseq rest end) #\?)
        (setf path p query q)))
    (multiple-value-bind (userinfo hostport) (%split-last authority #\@)
      (multiple-value-bind (host port) (%parse-host-port (or hostport "") url)
        (when (string= host "")
          (%fail url "no host"))
        (multiple-value-bind (user password) (%split-once (or userinfo "") #\:)
          (let* ((database (string-left-trim "/" (or path "")))
                 (sslmode (or (%query-value query "sslmode" url) "prefer")))
            ;; The default is `prefer', which is libpq's own default for a URL that says
            ;; nothing. It is NOT this framework inventing a policy: an operator who
            ;; pastes a provider's URL gets what psql would give them.
            (let ((normalized (string-downcase (string-trim " " sslmode))))
              (unless (be:ssl-mode-known? normalized)
                (%fail url "sslmode=~A is not one of disable, allow, prefer, require, verify-ca, verify-full"
                       normalized))
              (be:make-postgres-with-ssl
               (%decode host url "the host")
               (if port (%parse-port port url) 5432)
               (%decode database url "the database name")
               (%decode user url "the username")
               (%decode (or password "") url "the password")
               normalized))))))))

(defun backend-from-url (url)
  "Turn a connection URL into a typed BACKEND, or signal INVALID-DATABASE-URL.

  (backend-from-url \"postgres://u:p@db.example.com:25060/appdb?sslmode=require\")
  (backend-from-url \"sqlite:///data/app.db\")

Accepts `postgres://' and `postgresql://' -- both are in the wild, libpq takes either,
and tooling that takes only one breaks for somebody -- plus `sqlite://' and `sqlite3://'
so that ONE environment variable can configure every environment, which is what makes
dev/prod parity achievable rather than aspirational.

What it handles, because each of these is a real URL a provider emits:

  - the password is percent-encoded (generated ones contain @ / # ? and :)
  - the port is optional and defaults to 5432
  - the database name may be absent
  - the host may be a bracketed IPv6 literal
  - `?sslmode=' selects TLS; ABSENT MEANS `prefer', which is libpq's default

What stays with the application is which variable to read and what to fall back to --
that is policy. Turning the string into a Backend is not."
  (unless (stringp url)
    (%fail nil "expected a string"))
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) url)))
    (when (string= trimmed "")
      (%fail url "the URL is empty"))
    (multiple-value-bind (scheme rest) (%split-once trimmed #\:)
      (let ((scheme (string-downcase scheme)))
        (unless (and rest (>= (length rest) 2) (string= "//" (subseq rest 0 2)))
          (%fail url "no `://' after the scheme~@[ `~A'~]"
                 (and (plusp (length scheme)) scheme)))
        (let ((rest (subseq rest 2)))
          (cond
            ((or (string= scheme "postgres") (string= scheme "postgresql"))
             (%postgres-from-url rest url))
            ((or (string= scheme "sqlite") (string= scheme "sqlite3"))
             (%sqlite-from-url rest url))
            (t (%fail url "scheme `~A' is not one of postgres, postgresql, sqlite, sqlite3"
                      scheme))))))))
