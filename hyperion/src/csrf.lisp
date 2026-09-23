;;;; csrf.lisp --- Cross-site request forgery: the refusal half.
;;;;
;;;; A token in the session, compared against one the request carries. ADR-0019 settles the
;;;; shape: ONE mechanism pre- and post-authentication, because the page where a mistake is
;;;; worst -- sign-in -- is exactly the page a second mechanism would cover alone.
;;;;
;;;; THIS FILE IS THE HALF THAT REFUSES. The half that puts the token INTO a form is a
;;;; Spinneret `deftag' on :form and lands separately. The order is not a convenience:
;;;; the injector has three known holes (ADR-0019), and they are survivable only because
;;;; this file is authoritative. A form that misses injection is REFUSED here, loudly,
;;;; instead of being served unprotected and silently. Availability bug, not a security
;;;; one -- but only while the refusal below actually refuses.
;;;;
;;;; WHERE THE DANGER IS. Everything about a missed injection is loud. Everything about an
;;;; EXEMPTION is quiet: an exempted route with no token fails OPEN and nothing anywhere
;;;; complains. That is why exemptions are logged once, at construction, naming each one --
;;;; an exemption list is auditable in one place or it is not auditable at all.
;;;;
;;;; ORDERING. WRAP-CSRF reads the session from the env, so it goes INSIDE WRAP-SESSION:
;;;;
;;;;   (wrap-session (wrap-csrf (to-app router)) store)
;;;;
;;;; Outside it, every unsafe request is refused for want of a session. That is a loud
;;;; misconfiguration rather than a quiet hole, which is the way round this file wants it.

(in-package #:hyperion/csrf)

;;; --- vocabulary -----------------------------------------------------------

(defparameter *field-name* "_csrf"
  "The form field a token travels in. The injector emits this name.")

(defparameter *header-name* "X-CSRF-Token"
  "The header a token may travel in instead, so an HTMX request and an ordinary form post
share one verification path rather than two (ADR-0019 decision 4).")

(defparameter *token-bits* 256
  "Entropy per token. A CSRF token is a bearer credential and is sized like the session id.")

(defconstant +token-key+ :hyperion.csrf/token
  "The session key the token lives under. Namespaced: a session bag is the app's, and the
framework does not get to squat on a short name in it.")

(defparameter *safe-methods* '(:get :head :options :trace)
  "Methods that do not change state and are not checked.

HEAD and OPTIONS are here because they cannot carry an effect; GET is here because a GET
that changes state is already a defect this check cannot repair. Narrow on purpose -- every
method NOT in this list is checked, so a method added to HTTP tomorrow is checked by
default rather than exempt by omission.")

;;; --- failure --------------------------------------------------------------

(define-condition csrf-failure (error)
  ((reason :initarg :reason :reader csrf-failure-reason)
   (method :initarg :method :initform nil :reader csrf-failure-method)
   (path   :initarg :path   :initform nil :reader csrf-failure-path))
  (:documentation
   "A request that had to carry a valid token and did not. REASON is one of :NO-SESSION,
:NO-TOKEN-IN-SESSION, :MISSING or :MISMATCH -- distinguished because they mean different
things to whoever is reading the log. :MISMATCH is an attack or a stale tab; :NO-SESSION is
almost always WRAP-CSRF installed outside WRAP-SESSION.")
  (:report
   (lambda (c s)
     (format s "CSRF check failed (~A) for ~A ~A"
             (csrf-failure-reason c)
             (or (csrf-failure-method c) "?")
             (or (csrf-failure-path c) "?")))))

(defun forbidden (env condition)
  "The default refusal: 403 with a body that says which of the four reasons it was.

The reason is safe to disclose. It tells an attacker nothing they did not already know --
they know they did not send a valid token -- and it is the difference between a five-minute
diagnosis and an afternoon for the developer who installed the middleware in the wrong
order."
  (declare (ignore env))
  (list 403
        (list :content-type "text/plain; charset=utf-8")
        (list (format nil "Forbidden: CSRF check failed (~A)."
                      (string-downcase (csrf-failure-reason condition))))))

;;; --- the token ------------------------------------------------------------

(defun token (session)
  "SESSION's CSRF token, or NIL when it has none."
  (session:session-get session +token-key+))

(defun ensure-token (session)
  "SESSION's token, minting one into the session if it has none. Returns the token.

The bytes come from aion/random -- the same CSPRNG that mints session ids (#95), not
`cl:random'. A token from a predictable generator is not a token.

This is the seam the INJECTOR calls at response assembly. It is here rather than in the
injector so that the two halves agree on where a token lives by construction: there is one
function that can put one there."
  (or (token session)
      (let ((new (rnd:random-hex *token-bits*)))
        (session:session-set session +token-key+ new)
        new)))

(defun rotate-token (session)
  "Mint SESSION a NEW token, discarding the old one. Returns it.

Call at every privilege change, beside ROTATE-SESSION (ADR-0019 decision 6): a token minted
before the visitor authenticated is a token an attacker may have held."
  (let ((new (rnd:random-hex *token-bits*)))
    (session:session-set session +token-key+ new)
    new))

;;; --- the privilege change -------------------------------------------------
;;;
;;; A token minted before the visitor authenticated is a token an attacker may have held,
;;; exactly as a session id is (#282). Registering the key here rather than teaching
;;; SIGN-IN! about CSRF keeps session.lisp ignorant of what this value means, and means an
;;; app gets the rotation without knowing either half exists.
;;;
;;; DISCARDED, not re-minted: ENSURE-TOKEN mints lazily the next time a form needs one, so
;;; nothing has to know how to make one here.

(pushnew +token-key+ session:*privilege-scoped-keys*)

;;; --- comparison -----------------------------------------------------------

(defun constant-time-string= (a b)
  "STRING= for secrets: the time taken does not depend on WHERE the strings differ.

An ordinary STRING= returns at the first differing character, so the time it takes reveals
how long a correct prefix was -- and a few thousand requests turn that into the token. This
accumulates the difference over every character and tests it once at the end.

It DOES return early when the lengths differ, which leaks the length. That is the standard
trade: our tokens are a fixed width, so the length carries nothing, and hashing both sides
to equalise the comparison would cost more than it buys.

NIL for anything that is not a pair of strings, so a missing token can never compare equal
to anything."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (let ((diff 0))
         (declare (type (unsigned-byte 32) diff))
         (loop for ca across a
               for cb across b
               do (setf diff (logior diff (logxor (char-code ca) (char-code cb)))))
         (zerop diff))))

;;; --- what the request carries ---------------------------------------------

(defun %body-cached-p (env)
  (not (eq :%unread (getf env http:+body-string-key+ :%unread))))

(defun with-cached-body (env)
  "ENV with its urlencoded body read ONCE and cached, so reading the token does not consume
the body the handler is about to read.

The request body is a stream. Whoever reads it first gets it and everyone after gets NIL,
which is why a CSRF middleware that reads a form field is a classic way to break every POST
handler in an application while the check itself tests green.

A MULTIPART BODY IS PARSED, NOT BUFFERED. PARSE-MULTIPART already streams and already
spills a part over the threshold to disk, so parsing here costs no memory the handler was
not going to pay and applies every ceiling by construction -- and the handler then reads its
parts out of the env instead of re-parsing a stream that is gone. Reading only the FIRST
part was considered and is impossible: PARSE-MULTIPART is one loop over all parts, MAX-PARTS
signals rather than stopping, and the scanner has no rewind, so stopping early would leave
the handler scanning for an opening boundary that had already been consumed.

A body that cannot be parsed yields no parts. The caller treats that as carrying no token,
which refuses -- see WRAP-CSRF."
  (cond ((%body-cached-p env) env)
        ((%parts-cached-p env) env)
        ((http:multipart-p env)
         (handler-case (http:cache-multipart-parts env (http:parse-multipart env))
           (http:multipart-error () (http:cache-multipart-parts env :%unparseable))))
        ((null (getf env :raw-body)) env)
        (t (http:cache-body-string env (http:body-string env)))))

(defun %parts-cached-p (env)
  (not (eq :%unparsed (getf env http:+multipart-parts-key+ :%unparsed))))

(defun %cached-parts (env)
  "The parsed parts on ENV, or NIL when there are none or the body would not parse."
  (let ((p (getf env http:+multipart-parts-key+ :%unparsed)))
    (if (or (eq p :%unparsed) (eq p :%unparseable)) nil p)))

(defun %release-parts (env)
  "Delete any temp files the middleware\'s own parse spilled.

ONLY ON THE REFUSAL PATH. See WRAP-CSRF for why this must not happen when the app runs."
  (let ((parts (%cached-parts env)))
    (when parts (ignore-errors (http:delete-parts parts)))))

(defun request-token (env)
  "The token the request carries: the header, or the *FIELD-NAME* field of a urlencoded
body. NIL when it carries neither.

Call WITH-CACHED-BODY on ENV first if the handler will also read the body.

A MULTIPART request is read the same way, from the part of that name, so the injector\'s
hidden field works in a file-upload form exactly as in an ordinary one -- no header
requirement, no JS requirement, no ordering requirement on the form."
  (or (http:request-header env *header-name*)
      (if (http:multipart-p env)
          (let ((parts (%cached-parts env)))
            (and parts (http:multipart-param parts *field-name*)))
          (http:form-param (http:body-string env) *field-name*))))

(defun safe-method-p (method)
  "True when METHOD cannot change state and needs no token."
  (and (member method *safe-methods*) t))

;;; --- exemptions -----------------------------------------------------------
;;;
;;; The quiet surface. An exemption is a string (exact PATH-INFO match) or a predicate of
;;; the env. Nothing clever on purpose: a prefix or a regexp exemption is one typo away from
;;; exempting more than it names, and this is the list where that is least survivable.

(defun %exempt-p (env exemptions)
  (dolist (e exemptions nil)
    (when (etypecase e
            (string (string= e (or (getf env :path-info) "")))
            (function (funcall e env)))
      (return t))))

(defun %describe-exemption (e)
  (etypecase e
    (string e)
    (function (format nil "~A" e))))

;;; --- the injector ----------------------------------------------------------
;;;
;;; ADR-0019 decides that the token is put into every posting form at the response
;;; boundary, so that A FORM WRITTEN NEXT MONTH IS PROTECTED WITHOUT ITS AUTHOR KNOWING THE
;;; MECHANISM EXISTS. hyperion owns its HTML DSL, so the boundary can be the tag layer: a
;;; Spinneret DEFTAG on :form, consulted by PARSE-HTML before the standard-tag path
;;; (compile.lisp:31, ahead of the VALID? check at :35).
;;;
;;; THIS IS NOT THE SHAPE ADR-0019 RECORDS, and the difference is worth stating. The ADR
;;; expands to SPINNERET::WITH-TAG with an inner WITH-HTML around the children. That works
;;; -- it was tested -- but WITH-TAG is not exported, and the inner WITH-HTML is needed only
;;; because PARSE-HTML does not descend into a WITH-TAG form. DYNAMIC-TAG is public, emits
;;; by name at RUNTIME, and therefore cannot re-enter this deftag: the recursion the inner
;;; WITH-HTML was working around does not arise. Same output, public API, no gymnastics.
;;;
;;; THREE HOLES, AND THIS CLOSES ONE OF THEM.
;;;
;;;   1. COMPILE ORDER, still open. A template compiled BEFORE this file loads emits an
;;;      unprotected form and says nothing -- with fasl caching, an app can hold one built
;;;      against an older hyperion. Nothing in hyperion/src writes (:form today, so the
;;;      tree does not currently bite itself; a form added to a file that loads earlier
;;;      than this one would.
;;;   2. RUNTIME-NAMED TAGS, still open. DYNAMIC-TAG and INTERPRET-HTML-TREE emit by name
;;;      and never consult a deftag, so a data-driven render is unprotected. Note the irony
;;;      that this injector is BUILT on the mechanism that bypasses it.
;;;   3. GET FORMS -- CLOSED. The ADR notes a token would land in the query string on
;;;      submit (Referer, logs, history) and that a runtime check was needed. It is here:
;;;      the method is read at RUNTIME, so a computed one is handled, and a form with no
;;;      method at all is GET by HTML default and gets nothing.
;;;
;;; All three remain AVAILABILITY bugs rather than security ones, because the check half is
;;; authoritative: a form that misses injection has its POST refused and breaks loudly,
;;; rather than being served unprotected in silence.
;;;
;;; THE DEFTAG NAMESPACE IS GLOBAL TO THE IMAGE. Loading this system shadows :form for
;;; every Spinneret user in the process, not only for the app.

(defvar *token-thunk* nil
  "How the injector gets this request\'s token: a thunk, or NIL outside a request.

A THUNK rather than a token, so that nothing is minted for a response that renders no
form -- an anonymous visitor who never sees one never gets a token, and the store does not
fill with tokens minted for crawlers. WRAP-CSRF binds it around EVERY call to the
application, including safe methods, because a GET is precisely what renders the form.

NIL means no token is available and the field is not emitted, which is the honest outcome:
the resulting POST is refused, loudly, by the half of this file that refuses.")

(defun current-token ()
  "This request\'s token, minting it on first use, or NIL outside a request."
  (and *token-thunk* (funcall *token-thunk*)))

(defun %form-changes-state-p (method hx)
  "Does a form with this METHOD (a string, keyword or NIL) change state?

A form with NO method is GET by HTML default and does not. HX is true when the form carries
an hx-post/put/patch/delete attribute, which is how an HTMX form states its verb -- such a
form usually has no METHOD at all, and skipping it would leave the framework\'s own
idiom the one shape the injector missed."
  (or (and hx t)
      (let ((m (and method (string-downcase (princ-to-string method)))))
        (and m (not (member m (list "get" "dialog") :test (function string=)))))))

(defun token-field (&optional (method "post") hx)
  "Write the hidden token field for a form with METHOD, if one is warranted and available.

Exported so a form built by a path the deftag cannot reach -- DYNAMIC-TAG,
INTERPRET-HTML-TREE, hole 2 above -- can still be protected by asking for it."
  (let ((tok (current-token)))
    (when (and tok (%form-changes-state-p method hx))
      (spin:with-html (:input :type "hidden" :name *field-name* :value tok))
      t)))

(spin:deftag :form (body attrs &key)
  (let ((method (getf attrs :method))
        ;; PRESENCE is decided at expansion; the METHOD's VALUE is left to runtime.
        (hx (and (or (getf attrs :hx-post) (getf attrs :hx-put)
                     (getf attrs :hx-patch) (getf attrs :hx-delete))
                 t)))
    `(spin:dynamic-tag :name "form" ,@attrs
       (token-field ,method ,hx)
       ,@body)))

;;; --- the middleware -------------------------------------------------------

(defun check (env)
  "Signal CSRF-FAILURE unless ENV carries the token its session holds. Returns T.

Separate from the middleware so that it can be called with a request built by hand, with no
injector anywhere in the image. A refusal reachable only through the thing that satisfies it
is not a refusal, and this is the function the suite points at to prove otherwise."
  (let* ((session (session:request-session env))
         (expected (and session (token session)))
         (presented (request-token env))
         (method (getf env :request-method))
         (path (getf env :path-info)))
    (cond
      ((null session)
       (error 'csrf-failure :reason :no-session :method method :path path))
      ((null expected)
       (error 'csrf-failure :reason :no-token-in-session :method method :path path))
      ((null presented)
       (error 'csrf-failure :reason :missing :method method :path path))
      ((not (constant-time-string= expected presented))
       (error 'csrf-failure :reason :mismatch :method method :path path))
      (t t))))

(defun wrap-csrf (app &key exempt (on-failure #'forbidden))
  "Ring middleware refusing any state-changing request that does not carry its session's
CSRF token. Goes INSIDE WRAP-SESSION -- see this file's header.

EXEMPT is a list of exact PATH-INFO strings or predicates of the env. ON-FAILURE is called
with (env condition) and returns the response; it defaults to FORBIDDEN.

The refusal happens BEFORE the app is called, so no handler can bypass it and no handler
needs to know it exists. The app is deliberately invoked OUTSIDE the handler that catches
CSRF-FAILURE: an application free to signal that condition itself must not be able to
impersonate a refusal, and a middleware that wrapped the whole call could not tell the two
apart."
  (let ((exemptions (copy-list exempt)))
    (when exemptions
      (log:warn "csrf: exemptions configured -- each one fails OPEN"
                :count (length exemptions)
                :exemptions (mapcar #'%describe-exemption exemptions)))
    (lambda (env)
      ;; BOUND AROUND EVERY PATH, safe and exempt included. A GET is what RENDERS the form,
      ;; so binding this only for checked requests would leave every form tokenless -- the
      ;; injector would be installed and silent, which is the worst of both halves.
      (let* ((session (session:request-session env))
             (*token-thunk* (and session (lambda () (ensure-token session)))))
      (if (or (safe-method-p (getf env :request-method))
              (%exempt-p env exemptions))
          (funcall app env)
          (let* ((env (with-cached-body env))
                 (failure (handler-case (progn (check env) nil)
                            (csrf-failure (c) c))))
            (if failure
                (progn
                  (log:warn "csrf: refused"
                            :reason (csrf-failure-reason failure)
                            :method (getf env :request-method)
                            :path (getf env :path-info))
                  ;; THE MIDDLEWARE OWNS THE TEMP FILES ON THIS PATH ONLY, and the asymmetry
                  ;; is deliberate rather than an oversight -- read this before tidying it.
                  ;;
                  ;; When a multipart body is parsed here, parts over the memory threshold
                  ;; spill to disk. On the SUCCESS path the app receives those parts and
                  ;; deletes them exactly as it always has: ownership is unchanged, and the
                  ;; middleware MUST NOT delete them. A streamed response body is a function
                  ;; that runs AFTER the handler returns, so deleting here would pull the
                  ;; files out from under a stream still reading them -- the same
                  ;; head-before-body ordering that makes a cookie minted during render
                  ;; arrive too late (ADR-0019). The tidy is a use-after-free.
                  ;;
                  ;; On the REFUSAL path no app runs, so nobody else can ever delete them.
                  ;; Without this line every refused upload orphans its spilled files: a slow
                  ;; disk fill that nobody attributes to uploads, which is the failure
                  ;; PARSE-MULTIPART's own unwind-protect exists to prevent.
                  (%release-parts env)
                  (funcall on-failure env failure))
                (funcall app env))))))))
