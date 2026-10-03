;;;; store.lisp --- what the broker keeps, behind a protocol the app implements

(cl:in-package #:aion/oauth)

(defstruct (token-set (:constructor make-token-set
                          (&key access refresh expires-at scope resource issuer client-id
                                token-endpoint revocation-endpoint metadata-url)))
  "The tokens one principal holds for one connection, and where they came from.

ACCESS and REFRESH are AION/SECRET values, so neither can reach a log or a backtrace by
accident; REFRESH is NIL when the server issued none. EXPIRES-AT is a universal time, or NIL
when the server gave no lifetime. SCOPE is the space-separated scopes granted or requested.
RESOURCE is the canonical URI the tokens were issued for, and ISSUER the authorization server
that issued them: a token is never sent to another resource. CLIENT-ID, TOKEN-ENDPOINT and
REVOCATION-ENDPOINT are what a refresh and a disconnect need. METADATA-URL is where the
protected-resource metadata was found, so the issuer can be checked again later."
  access refresh expires-at scope resource issuer client-id token-endpoint revocation-endpoint
  metadata-url)

(defstruct (pending (:constructor make-pending
                       (&key principal connection resource issuer client-id verifier
                             token-endpoint revocation-endpoint iss-required scope expires-at
                             metadata-url)))
  "A sign-in in progress, kept under its STATE until the browser comes back. A store keeps every
slot: VERIFIER is an AION/SECRET value, whose text is AION/SECRET:REVEAL's; ISS-REQUIRED is a
boolean; EXPIRES-AT a universal time; the rest are strings, except PRINCIPAL, which is what the
app uses for its users."
  principal connection resource issuer client-id verifier token-endpoint revocation-endpoint
  iss-required scope expires-at metadata-url)

(defclass store () ()
  (:documentation "Where a broker keeps tokens, registered clients and sign-ins in progress.
An app implements the generic functions below over its own storage, typically encrypted at
rest. Keys are compared with EQUAL."))

(defgeneric get-token (store principal connection)
  (:documentation "The TOKEN-SET for PRINCIPAL and CONNECTION (a name), or NIL."))
(defgeneric put-token (store principal connection token-set)
  (:documentation "Keep TOKEN-SET for PRINCIPAL and CONNECTION, replacing any earlier one."))
(defgeneric delete-token (store principal connection)
  (:documentation "Forget the tokens for PRINCIPAL and CONNECTION."))
(defgeneric get-client (store issuer redirect-uri)
  (:documentation "The client id registered with ISSUER for REDIRECT-URI, or NIL."))
(defgeneric put-client (store issuer redirect-uri client-id)
  (:documentation "Keep CLIENT-ID, registered with ISSUER for REDIRECT-URI. A client is never
used with another issuer."))
(defgeneric put-pending (store state pending)
  (:documentation "Keep PENDING, a sign-in in progress, under STATE."))
(defgeneric take-pending (store state)
  (:documentation "Remove and return the sign-in kept under STATE, or NIL. Removing it is what
makes a STATE good for one use only."))

(defgeneric call-with-refresh-lock (store key thunk)
  (:documentation "Call THUNK while holding the refresh lock for KEY, a list of a principal and a
connection, and return its values. Two refreshes of one token must not run at once: with
refresh-token rotation, the second would present a refresh token the first had used up, be
refused, and sign the user out. The default method locks within this process; a store shared
by several instances overrides it with a lock they share, such as a database row lock."))

(defvar *refresh-locks* (make-hash-table :test #'equal)
  "KEY -> mutex, for the default CALL-WITH-REFRESH-LOCK.")

(defvar *refresh-locks-lock* (sb-thread:make-mutex :name "aion/oauth refresh locks"))

(defmethod call-with-refresh-lock ((store store) key thunk)
  (let ((lock (sb-thread:with-mutex (*refresh-locks-lock*)
                (or (gethash key *refresh-locks*)
                    (setf (gethash key *refresh-locks*)
                          (sb-thread:make-mutex :name "aion/oauth refresh"))))))
    (sb-thread:with-recursive-lock (lock)
      (funcall thunk))))

(defclass memory-store (store)
  ((tokens :initform (make-hash-table :test #'equal))
   (clients :initform (make-hash-table :test #'equal))
   (pending :initform (make-hash-table :test #'equal))
   (lock :initform (sb-thread:make-mutex :name "aion/oauth memory store")))
  (:documentation "A STORE in this process's memory. For tests, and for an app that runs as
one process. An app with several instances cannot use it: a sign-in started on one instance
and finished on another would not be found there. Nothing it holds survives a restart."))

(defun make-memory-store () (make-instance 'memory-store))

(defmacro %with-store ((store) &body body)
  `(sb-thread:with-mutex ((slot-value ,store 'lock)) ,@body))

(defmethod get-token ((s memory-store) principal connection)
  (%with-store (s) (gethash (list principal connection) (slot-value s 'tokens))))
(defmethod put-token ((s memory-store) principal connection token-set)
  (%with-store (s) (setf (gethash (list principal connection) (slot-value s 'tokens)) token-set)))
(defmethod delete-token ((s memory-store) principal connection)
  (%with-store (s) (remhash (list principal connection) (slot-value s 'tokens))))
(defmethod get-client ((s memory-store) issuer redirect-uri)
  (%with-store (s) (gethash (list issuer redirect-uri) (slot-value s 'clients))))
(defmethod put-client ((s memory-store) issuer redirect-uri client-id)
  (%with-store (s) (setf (gethash (list issuer redirect-uri) (slot-value s 'clients)) client-id)))
(defmethod put-pending ((s memory-store) state pending)
  ;; Expired sign-ins are dropped here, so one started and never finished does not keep its
  ;; record and verifier for the life of the process.
  (%with-store (s)
    (let ((table (slot-value s 'pending)) (now (get-universal-time)))
      (loop for key being the hash-keys of table using (hash-value p)
            when (< (pending-expires-at p) now) collect key into expired
            finally (dolist (k expired) (remhash k table)))
      (setf (gethash state table) pending))))
(defmethod take-pending ((s memory-store) state)
  (%with-store (s)
    (let ((p (gethash state (slot-value s 'pending))))
      (remhash state (slot-value s 'pending))
      p)))
