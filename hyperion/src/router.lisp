;;;; router.lisp --- URL dispatch: the effectful CL shell over hyperion/path.
;;;;
;;;; Before this, every Hyperion app hand-rolled the same `cond` over :request-method
;;;; and :path-info -- five of them in the tree, including praxeon/web (pre-publication issue 121). None
;;;; could express a path parameter, so no example had a detail view; all of them
;;;; answered 404 where 405 was correct; and none could be enumerated, which is what a
;;;; route listing or an OpenAPI emit (#46) would need.
;;;;
;;;; The split (docs/adr/0012): hyperion/path owns pattern parsing and matching, which
;;;; is real logic and typed in Coalton. This file owns what cannot be pure -- handler
;;;; closures, the Clack env, response shapes, and signalling on a bad declaration.
;;;;
;;;; Three properties worth naming, because they are why this is a framework capability
;;;; and not app code:
;;;;
;;;;   1. 405 is STRUCTURAL. Matching asks "does the path match" and "does the method
;;;;      match" as separate questions, so a path claimed by some route under another
;;;;      method answers 405 with a computed `Allow:`. A hand-rolled `(and (eq method
;;;;      :get) (string= path "/x"))` cannot distinguish those cases even in principle.
;;;;   2. HEAD and OPTIONS are DERIVED, never declared. HEAD is the GET route with the
;;;;      body dropped; OPTIONS answers from the same Allow set 405 uses. Deriving them
;;;;      means they cannot drift from the routes they describe.
;;;;   3. The table is DATA. ROUTES returns it; DESCRIBE-ROUTES prints it. A `cond` is
;;;;      opaque to everything, including its author.
;;;;
;;;; Handlers keep the ordinary Clack (env -> response) signature and bindings ride the
;;;; env under +PARAMS-KEY+ -- so porting a hand-rolled dispatcher moves the clauses
;;;; and touches no handler body.

(in-package #:hyperion/router)

;;; --- errors ---------------------------------------------------------------
;;; A malformed route is a programmer error at DECLARATION time, so it signals then
;;; rather than mis-routing quietly per request. The condition system, not a return
;;; code (AGENTS.md).

(define-condition route-error (error)
  ((message :initarg :message :reader route-error-message))
  (:report (lambda (c s) (format s "~A" (route-error-message c))))
  (:documentation "Signalled when a route declaration cannot mean anything sensible."))

(defun %fail (fmt &rest args)
  (error 'route-error :message (apply #'format nil fmt args)))

;;; --- the method vocabulary ------------------------------------------------
;;; Methods route through hyperion/htmx's typed Verb rather than a second enum: the
;;; hx-<verb> a link sends WITH and the method a route answers ON are one choice, and
;;; two copies could disagree. This is the house CL->Coalton bridge (cf.
;;; hyperion/html:verb-attr): CL passes a keyword, an ECASE selects a literal
;;; constructor INSIDE (coalton ...), and only a String comes back -- CL never holds a
;;; Coalton value, so nothing here depends on its representation
;;; (coalton-patterns.md §7).

(defmacro ecase-or-fail (keyform &body clauses)
  "Like ECASE but signals ROUTE-ERROR (naming the accepted keys) instead of a
CL type-error, so a bad route declaration reports in this vocabulary."
  (let ((k (gensym "K")))
    `(let ((,k ,keyform))
       (case ,k
         ,@clauses
         (t (%fail "~S is not a routable method; expected one of ~{~S~^ ~}."
                   ,k ',(mapcar #'first clauses)))))))

(defun %method-string (method)
  "The canonical HTTP method name for METHOD (:get :post :put :patch :delete), via the
typed renderer. Signals ROUTE-ERROR on anything else -- which is where a typo'd
method is caught: at route declaration, not on the request that needed it."
  (ecase-or-fail method
    (:get    (coalton:coalton (htmx:verb->method htmx:Get)))
    (:post   (coalton:coalton (htmx:verb->method htmx:Post)))
    (:put    (coalton:coalton (htmx:verb->method htmx:Put)))
    (:patch  (coalton:coalton (htmx:verb->method htmx:Patch)))
    (:delete (coalton:coalton (htmx:verb->method htmx:Delete)))))

;;; --- routes ---------------------------------------------------------------

(defstruct (route (:constructor %route) (:copier nil))
  "One declared route: a method, the template it was declared with (kept for
introspection), the parsed pattern, the parameter names, and the handler."
  (method :get :type keyword)
  (template "" :type string)
  (pattern nil)                       ; an OPAQUE hyperion/path:Pattern -- never inspected here
  (params '() :type list)             ; parameter names, in template order
  (handler nil :type (or function symbol))
  (name nil))

(defstruct (mount (:constructor %mount) (:copier nil))
  "A sub-router nested under a path prefix. The prefix is stripped (segment-aligned)
before the sub-router sees the request, so the same table routes identically whether
it is mounted or top-level."
  (prefix "" :type string)
  (router nil))

(defun route (method template handler &key name)
  "Declare a route: METHOD (:get :post :put :patch :delete), a path TEMPLATE
 (\"/contacts/:id\", \"/files/*\"), and HANDLER, an ordinary Clack (env -> response)
function. NAME is an optional keyword for introspection.

Three things are rejected here rather than at request time: an unroutable METHOD, a
`*` segment with anything after it (those segments could never match), and a repeated
parameter name (the second would silently shadow the first)."
  (%method-string method)                      ; validate; signals on a typo
  (let* ((pattern (path:parse-pattern template))
         (params (path:pattern-params pattern)))
    (unless (path:pattern-valid? pattern)
      ;; One line: a FORMAT ~<newline> continuation becomes an illegal ~<Return>
      ;; directive on a CRLF checkout (AGENTS.md).
      (%fail "Template ~S has a `*` segment that is not last; every segment after it is unreachable." template))
    (let ((dupes (remove-duplicates
                  (loop for p in params
                        when (< 1 (count p params :test #'string=)) collect p)
                  :test #'string=)))
      (when dupes
        (%fail "Template ~S repeats parameter name~P ~{~S~^, ~}; the later binding would shadow the earlier." template (length dupes) dupes)))
    (%route :method method :template template :pattern pattern
            :params params :handler handler :name name)))

(defun mount (prefix router)
  "Nest ROUTER under PREFIX. A request whose path begins with PREFIX (on a segment
boundary) is dispatched into ROUTER with the prefix stripped. This is how a framework
module contributes its own routes -- hyperion/dev's reload endpoints, praxeon/web's
chat surface -- instead of an app retyping them."
  (%mount :prefix prefix :router router))

(defun router (&rest entries)
  "A route table from ENTRIES (routes and mounts), matched in order -- FIRST MATCH
WINS, so a literal declared before a parameter shadows it, which is usually what you
want (`/contacts/new` before `/contacts/:id`). Returns the list itself: the table is
data, and ROUTES reads it back."
  (dolist (e entries)
    (unless (or (route-p e) (mount-p e))
      (%fail "~S is neither a route nor a mount." e)))
  (copy-list entries))

(defun routes (router)
  "ROUTER's entries, in match order. The table is data -- this is what a route
listing, a dev-time overview, or a spec emit reads."
  (copy-list router))

;;; --- parameters on the env ------------------------------------------------

(defconstant +params-key+ :hyperion.route-params
  "Clack env key carrying this request's path bindings, as an alist of
 (name-string . value-string). Handlers keep the plain (env -> response) shape, so
routing a hand-rolled handler changes nothing about it.")

(defun path-params (env)
  "This request's path bindings as an alist of (name . value) strings."
  (getf env +params-key+))

(defun path-param (env name)
  "The bound value of path parameter NAME (a string) for this request, or NIL.
Names match the template: `/contacts/:id` binds \"id\"; a `*` segment binds \"rest\"."
  (cdr (assoc name (path-params env) :test #'string=)))

(defun %bindings-alist (flat)
  "hyperion/path:PATH-BINDINGS returns a FLAT name/value list -- the promised
representation, so nothing here destructures a Coalton Tuple. Pair it up."
  (loop for (k v) on flat by #'cddr collect (cons k v)))

;;; --- responses ------------------------------------------------------------

(defparameter *not-found*
  (lambda (env)
    (declare (ignore env))
    (list 404 '(:content-type "text/plain; charset=utf-8") (list "Not Found")))
  "Handler used when no route claims the path. Rebind for an app-wide 404 page.")

(defparameter *method-not-allowed*
  (lambda (env allow)
    (declare (ignore env))
    (list 405 (list :content-type "text/plain; charset=utf-8" :allow allow)
          (list "Method Not Allowed")))
  "Handler used when the path matched but the method did not. Receives the env and
the computed ALLOW string, and must include it -- RFC 9110 requires `Allow` on a 405.")

(defun %allow-header (methods)
  "The `Allow` value for METHODS (keywords), canonical names, in declaration order,
plus the HEAD and OPTIONS this router derives."
  (let ((names (remove-duplicates (mapcar #'%method-string methods)
                                  :test #'string= :from-end t)))
    (format nil "~{~A~^, ~}"
            (append names
                    (when (member "GET" names :test #'string=) '("HEAD"))
                    '("OPTIONS")))))

(defun %strip-body (response)
  "RESPONSE with its body emptied -- a HEAD answer, which must carry the headers a
GET would and no content."
  (list (first response) (second response) '()))

(defun %prefix-match (prefix path)
  "PATH with PREFIX removed when PATH sits under it on a SEGMENT boundary, else NIL.
Segment-aligned so a `/api` mount claims `/api/x` but not `/apiary`."
  (let ((p (path:normalize-path prefix))
        (q (path:normalize-path path)))
    (cond ((string= p "/") q)
          ((string= q p) "/")
          ((and (< (length p) (length q))
                (string= p (subseq q 0 (length p)))
                (char= #\/ (char q (length p))))
           (subseq q (length p)))
          (t nil))))

;;; --- dispatch -------------------------------------------------------------

(defun %match-method (request-method route-method)
  "Does REQUEST-METHOD reach a route declared for ROUTE-METHOD? Exactly, or as HEAD
reaching GET -- the one derivation, kept here so it is stated once."
  (or (eq request-method route-method)
      (and (eq request-method :head) (eq route-method :get))))

(defun %dispatch (router env)
  "Walk ROUTER in order. Returns (values response allowed) -- RESPONSE is NIL when
nothing matched, and ALLOWED lists the methods whose routes DID match the path, which
is what turns an unmatched request into a 405 rather than a 404."
  (let ((method (getf env :request-method))
        (path (or (getf env :path-info) "/"))
        (allowed '()))
    (dolist (e router)
      (etypecase e
        (route
         (when (path:path-matches? (route-pattern e) path)
           (push (route-method e) allowed)
           (when (%match-method method (route-method e))
             (let* ((bindings (%bindings-alist
                               (path:path-bindings (route-pattern e) path)))
                    (env* (list* +params-key+ bindings env))
                    (response (funcall (route-handler e) env*)))
               (return-from %dispatch
                 (values (if (eq method :head) (%strip-body response) response)
                         allowed))))))
        (mount
         (let ((sub (%prefix-match (mount-prefix e) path)))
           (when sub
             (multiple-value-bind (response sub-allowed)
                 (%dispatch (mount-router e) (list* :path-info sub env))
               ;; A mount that matched the prefix but produced nothing still
               ;; contributes its methods -- otherwise a method mismatch inside a
               ;; mounted table would surface as 404 instead of 405.
               (setf allowed (append sub-allowed allowed))
               (when response
                 (return-from %dispatch (values response allowed)))))))))
    (values nil (reverse allowed))))

(defun dispatch (router env)
  "Route ENV through ROUTER and return a Clack response.

No route matched the path -> *NOT-FOUND*. The path matched but the method did not ->
*METHOD-NOT-ALLOWED* with a computed `Allow`. An OPTIONS request on a known path is
answered here from that same set (204 + Allow), so it can never disagree with the
routes it describes."
  (multiple-value-bind (response allowed) (%dispatch router env)
    (cond
      (response response)
      ((null allowed) (funcall *not-found* env))
      ((eq (getf env :request-method) :options)
       (list 204 (list :allow (%allow-header allowed)) '()))
      (t (funcall *method-not-allowed* env (%allow-header allowed))))))

(defun to-app (router)
  "ROUTER as a Clack app: a (env -> response) closure. This is the value passed to
hyperion/server:start, and -- because it is just a handler -- the value middleware
wraps."
  (lambda (env) (dispatch router env)))

;;; --- introspection --------------------------------------------------------

(defun describe-routes (router &key (stream *standard-output*) (prefix ""))
  "Print ROUTER's table to STREAM, mounts indented under their prefix. The point of
the table being data: a dev can see what the app answers without reading the source."
  (dolist (e router)
    (etypecase e
      (route
       (format stream "~&  ~6A ~A~A~@[  (~{:~A~^ ~})~]~@[  [~S]~]~%"
               (%method-string (route-method e)) prefix (route-template e)
               (route-params e) (route-name e)))
      (mount
       (format stream "~&  mount  ~A~A~%" prefix (mount-prefix e))
       (describe-routes (mount-router e) :stream stream
                        :prefix (concatenate 'string prefix (mount-prefix e))))))
  (values))
