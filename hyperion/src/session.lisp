;;;; session.lisp --- cookie-based HTTP sessions (generic web infra)
;;;;
;;;; A session is an id + a thread-safe key/value bag, opaque to Hyperion: the app
;;;; stores whatever it needs (e.g. which agent/conversation session this browser is
;;;; attached to). Backends live behind a small STORE protocol; MEMORY-STORE is the
;;;; in-memory default (a mnemosyne-backed store lands later). ENSURE-SESSION is the
;;;; request seam. Plus dev/REPL management: list, inspect, reset, and kill sessions.
;;;;
;;;; This is the HTTP layer of the two-layer session design (see the Elise session
;;;; architecture): N HTTP sessions attach to one praxeon agent/conversation session.

(cl:in-package #:hyperion/session)

;;; ------------------------------------------------------------------------
;;; A session.
;;; ------------------------------------------------------------------------
(defstruct (session (:constructor %make-session) (:conc-name session-))
  "One browser's session: an ID, a thread-safe DATA bag (arbitrary app keys), and
CREATED/ACCESSED universal-time stamps.

THE ID IS READ-ONLY TO EVERYONE OUTSIDE THIS FILE, and deliberately not a `:read-only'
slot. ROTATE-SESSION has to change it IN PLACE, because a rotation that returned a fresh
object would leave every reference already taken -- the one on the request env, the one a
handler bound at the top of its login -- pointing at a session that is no longer in the
store. Writes through those references would then vanish without a word, which is the
same class of silent defect rotation exists to close (#207).

So: the slot is writable, SESSION-ID is a plain reader with NO SETF expander, and nothing
outside ROTATE-SESSION ever assigns it. `%ID' rather than `ID' so that the generated
accessor is SESSION-%ID and cannot be reached by accident from a caller who meant the
reader."
  (%id "" :type string)
  (data (make-hash-table :test 'equal))
  (lock (bt:make-lock "hyperion-session"))
  (created 0 :type unsigned-byte)
  (accessed 0 :type unsigned-byte))

(defun session-id (session)
  "SESSION's id -- the bearer credential the browser holds in its cookie.

Changes only through ROTATE-SESSION, and there is no `(setf session-id)' to change it
any other way."
  (session-%id session))

(defun session-get (session key &optional default)
  "The value under KEY in SESSION's data bag, or DEFAULT."
  (bt:with-lock-held ((session-lock session))
    (gethash key (session-data session) default)))

(defun session-set (session key value)
  "Set KEY to VALUE in SESSION's data bag; return VALUE."
  (bt:with-lock-held ((session-lock session))
    (setf (gethash key (session-data session)) value)))

(defun session-del (session key)
  "Remove KEY from SESSION's data bag."
  (bt:with-lock-held ((session-lock session))
    (remhash key (session-data session))))

(defun session-keys (session)
  "The keys currently set in SESSION's data bag."
  (bt:with-lock-held ((session-lock session))
    (loop for k being the hash-keys of (session-data session) collect k)))

(defun reset-session (session)
  "Clear SESSION's data bag but keep its id (a 'restart' at the HTTP layer -- the
browser stays attached; the app-level state is wiped). Returns SESSION.

THIS IS NOT SESSION-FIXATION DEFENCE, and it reads exactly as though it were. The id is
KEPT, deliberately: this is a restart of app state for a browser that stays attached, not
a new credential. Calling it at sign-in leaves the visitor holding the same session id
after authenticating that they held before -- which is the whole of session fixation, and
a reviewer skimming the handler sees a reset and moves on (#207).

At a privilege boundary -- sign-in above all -- you want ROTATE-SESSION."
  (bt:with-lock-held ((session-lock session))
    (clrhash (session-data session)))
  session)

(defun restore-session (id &key (created 0) (accessed 0) (data nil))
  "Reconstruct a SESSION from persisted parts -- for a pluggable STORE backend loading a
row (e.g. a mnemosyne-backed store). DATA is an alist of (key . value) copied into a fresh
data bag. The in-memory store never needs this; a DB store does."
  (let ((s (%make-session :%id id :created created :accessed accessed)))
    (loop for (k . v) in data do (setf (gethash k (session-data s)) v))
    s))

(defun session-alist (session)
  "SESSION's data bag as an alist of (key . value) -- the inverse of RESTORE-SESSION's
:data, for a store backend serialising a session."
  (bt:with-lock-held ((session-lock session))
    (loop for k being the hash-keys of (session-data session) using (hash-value v)
          collect (cons k v))))

;;; ------------------------------------------------------------------------
;;; The store protocol: interchangeable backends (id -> session).
;;; ------------------------------------------------------------------------
(defgeneric store-ref (store id)
  (:documentation "The session under ID in STORE, or NIL."))
(defgeneric store-add (store session)
  (:documentation "Put SESSION into STORE; return SESSION."))
(defgeneric store-del (store id)
  (:documentation "Remove the session under ID from STORE; return T if present."))
(defgeneric store-count (store)
  (:documentation "How many sessions STORE holds."))
(defgeneric store-list (store)
  (:documentation "All sessions in STORE, as a list (order unspecified)."))

;;; --- the in-memory store ---
(defclass memory-store ()
  ((table :initform (make-hash-table :test 'equal) :reader ms-table)
   (lock  :initform (bt:make-lock "hyperion-session-store") :reader ms-lock))
  (:documentation "A thread-safe in-memory session store (id -> session)."))

(defun make-memory-store ()
  "A fresh in-memory session store."
  (make-instance 'memory-store))

(defmethod store-ref ((s memory-store) id)
  (bt:with-lock-held ((ms-lock s)) (values (gethash id (ms-table s)))))
(defmethod store-add ((s memory-store) session)
  (bt:with-lock-held ((ms-lock s))
    (setf (gethash (session-id session) (ms-table s)) session))
  session)
(defmethod store-del ((s memory-store) id)
  (bt:with-lock-held ((ms-lock s)) (remhash id (ms-table s))))
(defmethod store-count ((s memory-store))
  (bt:with-lock-held ((ms-lock s)) (hash-table-count (ms-table s))))
(defmethod store-list ((s memory-store))
  (bt:with-lock-held ((ms-lock s))
    (loop for v being the hash-values of (ms-table s) collect v)))

;;; ------------------------------------------------------------------------
;;; Session ids.
;;;
;;; A SESSION ID IS A BEARER CREDENTIAL. Whoever holds it is the user, so it must be
;;; unguessable -- and it is handed to the viewer as a cookie, which means an attacker can
;;; observe as much output as they care to collect.
;;;
;;; This used to be `cl:random' over an OS-seeded state, with a comment saying a CSPRNG was
;;; needed "before anything security-sensitive". SBCL's `cl:random' is MT19937, whose
;;; internal state is RECOVERABLE from observed output; after that, every future id is
;;; known. Seeding does not help, because the attack is on the output. That is a session
;;; hijacking primitive, and every consuming app inherited it (#95).
;;;
;;; The docstring below said "*ID-BITS* of entropy" throughout, which was the more dangerous
;;; half: a reader auditing this file found a reassuring number sitting directly above the
;;; problem.
;;; ------------------------------------------------------------------------
(defparameter *id-bits* 128
  "Bits of entropy in a session id. Must be a multiple of 8 -- AION/RANDOM:RANDOM-HEX
refuses a width it cannot render honestly.")

(defun new-id ()
  "A fresh session id: *ID-BITS* of cryptographically secure entropy, as lowercase hex.

The bytes come from the OS (aion/random), not from `cl:random'. No lock and no generator
state here any more: the OS generator is the shared, thread-safe one, so there is nothing
of ours for two threads to race over."
  (rnd:random-hex *id-bits*))

;;; ------------------------------------------------------------------------
;;; The HTTP seam: cookie <-> session.
;;; ------------------------------------------------------------------------
(defparameter *cookie-name* "hyperion-session" "Name of the session cookie.")
(defparameter *cookie-max-age* 86400 "Session cookie Max-Age, in seconds.")

(defun set-cookie-header (id &key (name *cookie-name*) (max-age *cookie-max-age*)
                                  (path "/") (http-only t) (same-site "Lax") secure)
  "A Set-Cookie header *value* binding cookie NAME to session ID. HttpOnly and
SameSite=Lax by default; pass SECURE for HTTPS-only."
  (with-output-to-string (s)
    (format s "~A=~A; Path=~A; Max-Age=~D; SameSite=~A" name id path max-age same-site)
    (when http-only (write-string "; HttpOnly" s))
    (when secure (write-string "; Secure" s))))

(defun ensure-session (env store &key (cookie-name *cookie-name*) (create t))
  "Resolve the browser's session for Clack request ENV against STORE. Returns
 (values SESSION SET-COOKIE): the session named by the request's cookie, or -- when
absent/unknown and CREATE is true -- a freshly minted one; SET-COOKIE is a
Set-Cookie header string to emit when a new session was created, else NIL. Touches
the resolved session's ACCESSED time."
  (let* ((id (http:cookie env cookie-name))
         (existing (and id (store-ref store id))))
    (cond
      (existing
       (setf (session-accessed existing) (get-universal-time))
       (values existing nil))
      (create
       (let* ((new (new-id))
              (now (get-universal-time))
              (session (%make-session :%id new :created now :accessed now)))
         (store-add store session)
         (values session (set-cookie-header new :name cookie-name))))
      (t (values nil nil)))))

(defun rotate-session (store session &key (cookie-name *cookie-name*)
                                          (max-age *cookie-max-age*)
                                          (path "/") (http-only t)
                                          (same-site "Lax") secure)
  "Give SESSION a NEW id, keep its data, and re-key it in STORE. Returns
 (values SESSION SET-COOKIE) -- the SAME session object, now under a fresh id, and the
Set-Cookie header value that tells the browser about it.

CALL THIS AT EVERY PRIVILEGE CHANGE, sign-in above all. An id minted before the visitor
authenticated is an id an attacker may have chosen and may still hold; rotating it is what
makes session fixation fail. RESET-SESSION does NOT do this and is the inviting wrong
answer next door -- see its docstring (#207).

Before this existed, an app wanting rotation had to assemble it from NEW-ID,
RESTORE-SESSION, STORE-ADD and STORE-DEL -- four calls to get right independently, with
nothing checking that it had.

THE OBJECT IS MUTATED, NOT REPLACED, and that is the point: the env, and any handler that
already bound this session, keep working. A version returning a new object would leave
those references pointing at something no longer in the store, and writes through them
would be lost in silence.

THE STORE IS NEVER WITHOUT THE SESSION. The new key goes in before the old one comes out,
so a concurrent lookup finds one or the other and never a hole."
  (let ((old-id (session-id session))
        (fresh  (new-id)))
    (setf (session-%id session) fresh)
    (store-add store session)
    (unless (string= old-id fresh)
      (store-del store old-id))
    (setf (session-accessed session) (get-universal-time))
    (values session
            (set-cookie-header fresh :name cookie-name :max-age max-age :path path
                                     :http-only http-only :same-site same-site
                                     :secure secure))))

(defparameter *privilege-scoped-keys* '()
  "Session keys DISCARDED at a privilege change, by SIGN-IN!.

A module that keeps a credential in the session bag registers its key here at load time,
and sign-in stops depending on anyone remembering that it exists. HYPERION/CSRF registers
its token key, so a token minted before the visitor authenticated cannot survive into the
session that authenticated (ADR-0019 decision 6).

DISCARDED rather than re-minted, deliberately: a key can be removed without knowing how to
make a new one, so registering costs nothing and this file stays ignorant of what any of
these values mean. Whoever owns the key mints a fresh one lazily, next time it is needed.")

(defun sign-in! (store env &rest data &key &allow-other-keys)
  "Authenticate this request\'s session: rotate its id, discard its privilege-scoped keys,
and store DATA. Returns (values SESSION SET-COOKIE).

    (sign-in! store env :user-id (user-id user))

THE ROTATION CANNOT BE SEPARATED FROM THE PRIVILEGE CHANGE. That is the whole reason this
exists (#282). ENSURE-SESSION is the function whose NAME sounds like what a sign-in wants
and is the wrong one: it REUSES the id the request arrived with, so the id a visitor held
before authenticating is the id they hold after. That reads correctly, works, and passes
tests -- a consuming app shipped exactly it.

A docstring on ROTATE-SESSION was not enough, and it is worth recording why. The textbook
attack FAILS here: the store honours only ids it minted, so an invented cookie is ignored,
and anyone reasoning about \"attacker plants a cookie\" correctly concludes it does not
work. The version that works needs one more move -- the attacker signs in AS THEMSELVES to
mint a store-valid id, donates that cookie, and waits. Reasoning stops one move early and
the conclusion flips. A reader who checks is not protected by being told to check.

ALWAYS ROTATES, including when the request carried no session at all. A branch would mean
one path through here that does not rotate, and the invariant worth having is that there is
no such path.

The SET-COOKIE returned carries this function\'s defaults. Under WRAP-SESSION it is
redundant -- the middleware sees the id change and emits the cookie with ITS options, which
is where cookie policy belongs; this value is for an app driving sessions without it."
  (let ((session (or (request-session env)
                     (ensure-session env store))))
    (dolist (k *privilege-scoped-keys*)
      (session-del session k))
    (multiple-value-bind (s set-cookie) (rotate-session store session)
      (loop for (k v) on data by #'cddr do (session-set s k v))
      (values s set-cookie))))

;;; ------------------------------------------------------------------------
;;; The middleware: a Set-Cookie a handler cannot drop.
;;;
;;; ENSURE-SESSION returns the cookie as a SECOND VALUE, and a second value is a contract
;;; nothing enforces. Ignore it and every request mints a fresh session: nothing persists,
;;; sign-in does nothing, and every handler still reads correctly on its own. That failure
;;; is invisible at the call site and cost a consuming app real time (#207).
;;;
;;; So the house move rather than a docstring: WRAP-SESSION holds the header itself and the
;;; application never touches it. There is no second value to drop because the app is not
;;; given one -- the wrong thing is unrepresentable rather than discouraged, as with
;;; AION/RANDOM shadowing CL:RANDOM (#95) and payments having no operation that accepts a
;;; card number (#48).
;;;
;;; It also covers rotation without being told about it: the id is read on the way in and
;;; compared on the way out, so a handler that calls ROTATE-SESSION gets the new cookie
;;; emitted whether or not it remembered that one was owed.
;;; ------------------------------------------------------------------------

(defconstant +session-key+ :hyperion.session
  "Clack env key carrying this request's session, put there by WRAP-SESSION. Handlers keep
the plain (env -> response) shape; REQUEST-SESSION reads it.")

(defun request-session (env)
  "This request's session, or NIL when the app is not wrapped in WRAP-SESSION."
  (getf env +session-key+))

(define-condition session-cookie-not-attachable (error)
  ((response :initarg :response :reader session-cookie-not-attachable-response))
  (:report
   (lambda (c stream)
     (format stream "hyperion/session: a Set-Cookie is owed for this request but the ~
handler returned ~S, which is not a (status headers body) response and cannot carry it."
             (session-cookie-not-attachable-response c))))
  (:documentation
   "Signalled when WRAP-SESSION owes the browser a session cookie and the handler's
response cannot carry one. It SIGNALS rather than passing the response through, because
dropping the header quietly here would reinstate exactly the defect this middleware
exists to remove."))

(defun %ring-response-p (response)
  "True for a proper (status headers body) list whose headers are a list."
  (and (consp response) (consp (cdr response)) (consp (cddr response))
       (null (cdddr response)) (listp (second response))))

(defun %attach-set-cookie (response value)
  "RESPONSE with VALUE added as a Set-Cookie header. Appended, not merged: more than one
Set-Cookie on a response is ordinary HTTP, and ours going last is what a client keeps."
  (unless (%ring-response-p response)
    (error 'session-cookie-not-attachable :response response))
  (destructuring-bind (status headers body) response
    (list status (append headers (list :set-cookie value)) body)))

(defun wrap-session (app store &key (cookie-name *cookie-name*)
                                    (max-age *cookie-max-age*)
                                    (path "/") (http-only t)
                                    (same-site "Lax") secure)
  "Ring middleware giving APP a session from STORE and owning the cookie for it.

Resolves the browser's session (minting one when there is none), puts it on the env under
+SESSION-KEY+ where REQUEST-SESSION reads it, and attaches the Set-Cookie the response
owes -- on a mint, and on a ROTATE-SESSION performed anywhere inside the handler.

    (wrap-session (to-app router) store :secure t)

    (defun sign-in (env)
      (let ((s (session:request-session env)))
        (session:rotate-session store s)          ; the cookie is not yours to emit
        (session:session-set s :user-id id)
        (list 200 () (list \"welcome\"))))

The cookie options are this middleware's, applied to both cases, so `:secure t' holds for
a rotation as much as for a mint."
  (lambda (env)
    (multiple-value-bind (session minted) (ensure-session env store :cookie-name cookie-name)
      (let* ((entry-id (session-id session))
             (response (funcall app (list* +session-key+ session env)))
             (owed (or (and minted t)
                       (not (string= entry-id (session-id session))))))
        (if owed
            (%attach-set-cookie
             response
             (set-cookie-header (session-id session)
                                :name cookie-name :max-age max-age :path path
                                :http-only http-only :same-site same-site :secure secure))
            response)))))

;;; ------------------------------------------------------------------------
;;; Dev / REPL session management (introspect, reset, kill). Data/render split:
;;; SESSION-SUMMARY returns a plist (the structured hook), DESCRIBE-SESSIONS prints.
;;; ------------------------------------------------------------------------
(defun sessions (store)
  "All sessions in STORE (a list) -- for REPL inspection."
  (store-list store))

(defun session-summary (session)
  "A plist summary of SESSION: :id, :created, :accessed, :keys (data-bag keys)."
  (list :id (session-id session)
        :created (session-created session)
        :accessed (session-accessed session)
        :keys (session-keys session)))

(defun describe-sessions (store &optional (stream *standard-output*))
  "Print STORE's active sessions to STREAM (dev DX). Returns the session count."
  (let ((all (sessions store)))
    (format stream "~&~D active session~:P:~%" (length all))
    (dolist (s all)
      (let ((sum (session-summary s)))
        (format stream "  ~A  created ~A  accessed ~A  keys ~S~%"
                (getf sum :id) (getf sum :created) (getf sum :accessed)
                (getf sum :keys))))
    (length all)))

(defun kill-session (store id-or-session)
  "Evict a session from STORE by id or by the session object. Returns T if present."
  (store-del store (if (session-p id-or-session)
                       (session-id id-or-session)
                       id-or-session)))

(defun kill-sessions (store &optional predicate)
  "Evict sessions from STORE: all of them, or -- when PREDICATE is supplied -- only
those for which (PREDICATE session) is true. Returns the number evicted."
  (let ((victims (if predicate
                     (remove-if-not predicate (sessions store))
                     (sessions store))))
    (dolist (s victims) (store-del store (session-id s)))
    (length victims)))
