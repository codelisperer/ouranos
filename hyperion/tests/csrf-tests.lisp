;;;; csrf-tests.lisp --- hyperion/csrf: the refusal half (pre-publication issue 280, ADR-0019).
;;;;
;;;; EVERY REQUEST IN THIS FILE IS BUILT BY HAND. There is no injector in the image and no
;;;; request builder that could quietly attach a token: a refusal reachable only through the
;;;; thing that satisfies it is not a refusal, and a forgery fixture that forges nothing is
;;;; the documented way this exact feature tests green over broken code (ADR-0019).
;;;;
;;;; The first test is the control for all the others: it proves the unsigned request really
;;;; is unsigned, by both carriers, before anything asserts that it gets refused.

(in-package #:hyperion/tests)

(def-suite csrf :description "CSRF: the refusal half." :in hyperion)
(in-suite csrf)

;;; --- fixtures, deliberately dumb ------------------------------------------

(defun %csrf-session (&optional token)
  "A session, optionally already holding TOKEN. Built through the real store."
  (let* ((store (session:make-memory-store))
         (h (make-hash-table :test #'equal))
         (s (session:ensure-session (list :headers h) store)))
    (when token (session:session-set s csrf:+token-key+ token))
    s))

(defun %csrf-env (&key (method :post) (path "/x") header body session content-type)
  "A request built BY HAND. Nothing here attaches a token unless the caller asks for one --
HEADER puts it in X-CSRF-Token, BODY is a urlencoded string installed as the already-read
body. Both default to absent."
  (let ((h (make-hash-table :test #'equal)))
    (when header (setf (gethash "x-csrf-token" h) header))
    (let ((env (list :request-method method :path-info path :headers h)))
      (when content-type (setf env (list* :content-type content-type env)))
      (when body (setf env (http:cache-body-string env body)))
      (when session (setf env (list* session:+session-key+ session env)))
      env)))

(defun %csrf-stream-env (string &key (method :post) (path "/x") session)
  "An env whose :RAW-BODY is a REAL octet stream over STRING, so a test can observe whether
reading it spends it. Returns (values env pathname); the caller closes and deletes."
  (let* ((octets (sb-ext:string-to-octets string :external-format :utf-8))
         (tmp (uiop:tmpize-pathname (merge-pathnames "hyperion-csrf-test"
                                                     (uiop:temporary-directory)))))
    (with-open-file (out tmp :direction :output :element-type '(unsigned-byte 8)
                             :if-exists :supersede)
      (write-sequence octets out))
    (let ((env (list :request-method method :path-info path
                     :headers (make-hash-table :test #'equal)
                     :raw-body (open tmp :element-type '(unsigned-byte 8))
                     :content-length (length octets))))
      (when session (setf env (list* session:+session-key+ session env)))
      (values env tmp))))

(defmacro %with-stream-env ((env tmp string &rest options) &body forms)
  `(multiple-value-bind (,env ,tmp) (%csrf-stream-env ,string ,@options)
     (unwind-protect (progn ,@forms)
       (ignore-errors (close (getf ,env :raw-body)))
       (ignore-errors (delete-file ,tmp)))))

(defun %csrf-reason (env)
  "The reason CHECK refuses ENV, or NIL if it does not refuse."
  (handler-case (progn (csrf:check env) nil)
    (csrf:csrf-failure (c) (csrf:csrf-failure-reason c))))

(defmacro %quietly (&body forms)
  "Run FORMS with logging turned down. WRAP-CSRF warns on every refusal, which is right in
production and would bury the suite here."
  `(unwind-protect (progn (aion/log:level! :error) ,@forms)
     (aion/log:level! :warn)))

;;; --- the control: the forgery is genuinely unsigned ------------------------

(test a-hand-built-request-carries-no-token-by-either-carrier
  ;; THE CONTROL FOR THIS WHOLE FILE. If the fixture quietly attached a token, every
  ;; refusal test below would pass while testing nothing.
  (let ((env (%csrf-env)))
    (is (null (http:request-header env "x-csrf-token"))
        "the fixture must not attach a header token")
    (is (null (http:form-param (http:body-string env) "_csrf"))
        "the fixture must not attach a body token")
    (is (null (csrf:request-token env))
        "and REQUEST-TOKEN must agree that there is none")))

;;; --- the refusal ----------------------------------------------------------

(test check-refuses-a-state-changing-request-with-no-token
  (is (eq :missing (%csrf-reason (%csrf-env :session (%csrf-session "TOK"))))))

(test check-refuses-a-wrong-token
  (is (eq :mismatch (%csrf-reason (%csrf-env :session (%csrf-session "TOK")
                                             :header "NOT-THE-TOKEN")))))

(test check-refuses-when-there-is-no-session-at-all
  ;; WRAP-CSRF installed outside WRAP-SESSION. Loud misconfiguration, not a quiet hole.
  (is (eq :no-session (%csrf-reason (%csrf-env)))))

(test check-refuses-when-the-session-holds-no-token
  (is (eq :no-token-in-session
          (%csrf-reason (%csrf-env :session (%csrf-session) :header "ANYTHING")))))

(test a-token-that-is-a-prefix-of-the-real-one-is-refused
  ;; The shape a timing attack would build toward.
  (is (eq :mismatch (%csrf-reason (%csrf-env :session (%csrf-session "abcdef")
                                             :header "abc")))))

;;; --- acceptance, by both carriers -----------------------------------------

(test check-accepts-the-token-in-the-header
  (is (null (%csrf-reason (%csrf-env :session (%csrf-session "TOK") :header "TOK")))))

(test check-accepts-the-token-in-the-form-field
  (is (null (%csrf-reason (%csrf-env :session (%csrf-session "TOK")
                                     :body "_csrf=TOK&q=1")))))

(test both-carriers-reach-the-same-verification-path
  ;; ADR-0019 decision 4: HTMX and an ordinary form post must not have two code paths.
  (let ((s (%csrf-session "TOK")))
    (is (equal "TOK" (csrf:request-token (%csrf-env :session s :header "TOK"))))
    (is (equal "TOK" (csrf:request-token (%csrf-env :session s :body "_csrf=TOK"))))))

;;; --- safe methods ---------------------------------------------------------

(test a-safe-method-needs-no-token-and-an-unsafe-one-does
  ;; Both directions, on the SAME path and session, so the pass cannot be an artefact of
  ;; something else about the request.
  (%quietly
   (let* ((s (%csrf-session "TOK"))
          (app (lambda (env) (declare (ignore env)) (list 200 nil (list "ok"))))
          (wrapped (csrf:wrap-csrf app)))
     (is (= 200 (first (funcall wrapped (%csrf-env :method :get :session s)))))
     (is (= 403 (first (funcall wrapped (%csrf-env :method :post :session s))))))))

(test every-method-not-named-safe-is-checked
  ;; Exempt-by-omission is the failure mode: a method nobody listed must be CHECKED.
  (%quietly
   (let* ((s (%csrf-session "TOK"))
          (app (lambda (env) (declare (ignore env)) (list 200 nil (list "ok"))))
          (wrapped (csrf:wrap-csrf app)))
     (dolist (m '(:post :put :patch :delete :propfind))
       (is (= 403 (first (funcall wrapped (%csrf-env :method m :session s))))
           "~A must be checked" m)))))

;;; --- the middleware refuses before the app runs ---------------------------

(test the-app-is-never-reached-by-a-refused-request
  ;; "Refuses before routing" is the property; a handler that runs has already had its
  ;; chance to do the damage.
  (%quietly
   (let* ((reached nil)
          (app (lambda (env) (declare (ignore env)) (setf reached t) (list 200 nil nil)))
          (wrapped (csrf:wrap-csrf app)))
     (funcall wrapped (%csrf-env :session (%csrf-session "TOK")))
     (is (null reached) "the handler must not run for a refused request"))))

(test a-refusal-is-403-and-names-its-reason
  (%quietly
   (let* ((app (lambda (env) (declare (ignore env)) (list 200 nil nil)))
          (resp (funcall (csrf:wrap-csrf app)
                         (%csrf-env :session (%csrf-session "TOK")))))
     (is (= 403 (first resp)))
     (is (search "csrf" (string-downcase (format nil "~A" (third resp))))))))

;;; --- the quiet surface ----------------------------------------------------

(test an-exempt-path-fails-OPEN-and-that-is-the-point-of-writing-it-down
  ;; Asserted so the behaviour is documented rather than discovered. ADR-0019's review
  ;; instruction: everything about the injector's holes is loud, everything about an
  ;; exemption is quiet. This is the quiet thing, pinned.
  (%quietly
   (let* ((app (lambda (env) (declare (ignore env)) (list 200 nil (list "ok"))))
          (wrapped (csrf:wrap-csrf app :exempt (list "/sign-in"))))
     (is (= 200 (first (funcall wrapped (%csrf-env :path "/sign-in"
                                                   :session (%csrf-session "TOK")))))
         "an exempted path passes with no token -- fails OPEN by construction")
     (is (= 403 (first (funcall wrapped (%csrf-env :path "/other"
                                                   :session (%csrf-session "TOK")))))
         "and the exemption does not leak to a path it does not name"))))

(test an-exemption-matches-the-whole-path-and-not-a-prefix
  (%quietly
   (let* ((app (lambda (env) (declare (ignore env)) (list 200 nil (list "ok"))))
          (wrapped (csrf:wrap-csrf app :exempt (list "/sign-in"))))
     (is (= 403 (first (funcall wrapped (%csrf-env :path "/sign-in/evil"
                                                   :session (%csrf-session "TOK")))))
         "a prefix match would exempt more than the list names"))))

;;; --- the body the handler still needs -------------------------------------

(test a-body-stream-is-spent-by-its-first-reader
  ;; THE CONTROL for the test below. The hazard has to be real before the fix means
  ;; anything: this is what happens with no cache in play.
  (%with-stream-env (env tmp "q=hello")
    (is (equal "q=hello" (http:body-string env)) "the first read gets the body")
    (is (null (http:body-string env))
        "the second read returns NIL -- the stream is spent, and a short read decodes
nothing rather than a string of NULs")))

(test a-short-read-decodes-nothing-rather-than-NUL-padding
  ;; Content-Length is what the client CLAIMS. When fewer bytes arrive than claimed, the
  ;; unread tail of the buffer must not be decoded: a same-length string of NULs reads as
  ;; "the field was absent" at every call site, which is the silent shape.
  (%with-stream-env (env tmp "q=hello")
    (setf (getf env :content-length) 500)   ; claim far more than the body holds
    (let ((s (http:body-string env)))
      (is (equal "q=hello" s)
          "only the bytes that actually arrived are decoded, got ~S" s))))

(test the-check-does-not-spend-the-body-the-handler-will-read
  ;; The regression this design exists to avoid: a CSRF middleware that reads _csrf out of
  ;; the body breaks every POST handler downstream while its own tests stay green.
  (%with-stream-env (env tmp "_csrf=TOK&q=hello" :session (%csrf-session "TOK"))
    (let* ((seen :never-ran)
           (app (lambda (e)
                  (setf seen (http:form-param (http:body-string e) "q"))
                  (list 200 nil (list "ok"))))
           (resp (funcall (csrf:wrap-csrf app) env)))
      (is (= 200 (first resp)) "the token was found in the body and accepted")
      (is (equal "hello" seen)
          "the handler read the body AFTER the check did, and still got it"))))

(test a-cached-body-is-readable-more-than-once
  (let ((env (http:cache-body-string (list :headers (make-hash-table :test #'equal))
                                     "a=1&b=2")))
    (is (equal "a=1&b=2" (http:body-string env)))
    (is (equal "a=1&b=2" (http:body-string env)))
    (is (equal "2" (http:form-param (http:body-string env) "b")))))

;;; --- multipart: parsed once, cached, and the ownership asymmetry ----------
;;;
;;; The hidden field works in a file-upload form exactly as in an ordinary one. Reading only
;;; the FIRST part was considered and is impossible -- PARSE-MULTIPART is one loop over all
;;; parts, MAX-PARTS signals rather than stopping, and the scanner has no rewind, so
;;; stopping early would leave the handler scanning for a boundary already consumed.

(defun %upload-spills ()
  "Temp files PARSE-MULTIPART has spilled and nobody has deleted yet."
  (remove-if-not (lambda (p)
                   (let ((n (pathname-name p)))
                     (and n (search "hyperion-upload" n))))
                 (uiop:directory-files (uiop:temporary-directory))))

(defun %mp-request (body session)
  "A multipart POST over a REAL octet stream, with SESSION on the env.
Returns (values env temp-pathname); the caller closes and deletes."
  (multiple-value-bind (env tmp) (%mp-env body)
    (values (list* :request-method :post :path-info "/upload"
                   :headers (make-hash-table :test #'equal)
                   session:+session-key+ session
                   env)
            tmp)))

(defmacro %with-mp ((env tmp body session) &body forms)
  `(multiple-value-bind (,env ,tmp) (%mp-request ,body ,session)
     (unwind-protect (progn ,@forms)
       (ignore-errors (close (getf ,env :raw-body)))
       (ignore-errors (delete-file ,tmp)))))

(test a-multipart-form-carries-its-token-in-a-part-like-any-other-form
  (%with-mp (env tmp (%mp-body "BOUND" (list (list "_csrf" "TOK")
                                             (list "note" "hi")))
                 (%csrf-session "TOK"))
    (let* ((seen :never-ran)
           (app (lambda (e)
                  (setf seen (http:multipart-param (http:parse-multipart e) "note"))
                  (list 200 nil (list "ok"))))
           (resp (funcall (csrf:wrap-csrf app) env)))
      (is (= 200 (first resp)) "the token was found in a part and accepted")
      (is (equal "hi" seen)
          "and the handler still read the body AFTER the check parsed it -- the stream was
spent, so this can only have come from the cache"))))

(test a-multipart-request-without-a-token-is-refused
  (%quietly
   (%with-mp (env tmp (%mp-body "BOUND" (list (list "note" "hi"))) (%csrf-session "TOK"))
     (let ((app (lambda (e) (declare (ignore e)) (list 200 nil nil))))
       (is (= 403 (first (funcall (csrf:wrap-csrf app) env))))))))

(test a-multipart-request-may-still-carry-its-token-in-the-header
  (%with-mp (env tmp (%mp-body "BOUND" (list (list "note" "hi"))) (%csrf-session "TOK"))
    (setf (gethash "x-csrf-token" (getf env :headers)) "TOK")
    (let ((app (lambda (e) (declare (ignore e)) (list 200 nil (list "ok")))))
      (is (= 200 (first (funcall (csrf:wrap-csrf app) env)))))))

(test a-successful-upload-keeps-its-spilled-file-for-the-app-to-delete
  ;; OWNERSHIP IS UNCHANGED ON THE SUCCESS PATH. The middleware must NOT delete: a streamed
  ;; response body runs AFTER the handler returns, so deleting here would pull the files out
  ;; from under a stream still reading them.
  (let ((http:*memory-threshold* 8))          ; force a spill
    (%with-mp (env tmp (%mp-body "BOUND" (list (list "_csrf" "TOK")
                                               (list "f" "0123456789ABCDEF"
                                                     :filename "big.bin")))
                   (%csrf-session "TOK"))
      (let* ((seen nil)
             (app (lambda (e) (setf seen (http:parse-multipart e)) (list 200 nil nil)))
             (resp (funcall (csrf:wrap-csrf app) env))
             (f (and seen (http:find-part seen "f"))))
        (is (= 200 (first resp)))
        (is (and f (http:part-path f)) "precondition: the part actually spilled to disk")
        ;; HELD SEPARATELY: DELETE-PARTS nils PART-PATH as it goes, so reading it afterwards
        ;; asks the wrong object whether the file is gone.
        (let ((path (and f (http:part-path f))))
          (is (probe-file path)
              "the middleware did NOT delete it -- the app owns it, exactly as before")
          (http:delete-parts seen)
          (is (null (probe-file path)) "and the app's own delete still works"))))))

(test a-refused-upload-does-not-orphan-the-file-it-spilled
  ;; THE OTHER HALF OF THE ASYMMETRY. On the refusal path no app runs, so nobody else can
  ;; ever delete these. Without the middleware doing it, every refused upload leaks a temp
  ;; file -- a slow disk fill nobody attributes to uploads.
  (%quietly
   (let ((http:*memory-threshold* 8))
     (let ((before (length (%upload-spills))))
       (%with-mp (env tmp (%mp-body "BOUND" (list (list "f" "0123456789ABCDEF"
                                                        :filename "big.bin")))
                      (%csrf-session "TOK"))
         (let ((app (lambda (e) (declare (ignore e)) (list 200 nil nil))))
           (is (= 403 (first (funcall (csrf:wrap-csrf app) env))) "no token -> refused")
           (is (= before (length (%upload-spills)))
               "the refusal deleted what it spilled; ~D file(s) leaked"
               (- (length (%upload-spills)) before))))))))

(test a-multipart-body-that-will-not-parse-is-refused-rather-than-signalling
  ;; A body with no parts to read carries no token. Fails closed, and the error does not
  ;; escape the middleware into a handler that never ran.
  (%quietly
   (%with-mp (env tmp "this is not a multipart body at all" (%csrf-session "TOK"))
     (let ((app (lambda (e) (declare (ignore e)) (list 200 nil nil))))
       (is (= 403 (first (funcall (csrf:wrap-csrf app) env))))))))

;;; --- the token ------------------------------------------------------------

(test ensure-token-mints-once-and-is-stable
  (let* ((s (%csrf-session))
         (a (csrf:ensure-token s))
         (b (csrf:ensure-token s)))
    (is (stringp a))
    (is (plusp (length a)))
    (is (equal a b) "a second call must not mint a second token")
    (is (equal a (csrf:token s)))))

(test two-sessions-do-not-share-a-token
  (let ((a (csrf:ensure-token (%csrf-session)))
        (b (csrf:ensure-token (%csrf-session))))
    (is (not (equal a b)))))

(test rotate-token-replaces-it
  (let* ((s (%csrf-session))
         (before (csrf:ensure-token s))
         (after (csrf:rotate-token s)))
    (is (not (equal before after)))
    (is (equal after (csrf:token s)))
    (is (eq :mismatch (%csrf-reason (%csrf-env :session s :header before)))
        "the token minted before the privilege change no longer verifies")))

;;; --- comparison -----------------------------------------------------------

(test constant-time-compare-agrees-with-string=-on-what-is-equal
  (is-true (csrf:constant-time-string= "abc" "abc"))
  (is-true (csrf:constant-time-string= "" ""))
  (is-false (csrf:constant-time-string= "abc" "abd"))
  (is-false (csrf:constant-time-string= "abc" "abcd"))
  (is-false (csrf:constant-time-string= "abc" "ab")))

(test constant-time-compare-refuses-anything-that-is-not-a-pair-of-strings
  ;; A missing token is NIL, and NIL must never compare equal to a real token.
  (is-false (csrf:constant-time-string= nil nil))
  (is-false (csrf:constant-time-string= nil "abc"))
  (is-false (csrf:constant-time-string= "abc" nil))
  (is-false (csrf:constant-time-string= :abc "abc")))

(test the-comparison-looks-at-every-character
  ;; Not a timing measurement -- a correctness one. Difference in the LAST position must be
  ;; caught as surely as one in the first, which is what the accumulate-then-test shape buys.
  (let ((tok (make-string 64 :initial-element #\a)))
    (dolist (i (list 0 31 63))
      (let ((other (copy-seq tok)))
        (setf (char other i) #\b)
        (is-false (csrf:constant-time-string= tok other)
                  "a difference at position ~D must be caught" i)))))

;;; --- rotation at the privilege change (#120 + ADR-0019 decision 6) --------

(test the-csrf-package-registers-its-key-as-privilege-scoped
  ;; The wiring itself, asserted. If this registration is ever lost the token stops
  ;; rotating at sign-in and NOTHING ELSE FAILS -- the tests below would still pass on a
  ;; session that happened to hold no token.
  (is (member csrf:+token-key+ session:*privilege-scoped-keys*)
      "hyperion/csrf must register its key, or sign-in! cannot know to discard it"))

(test sign-in-discards-a-token-minted-before-authentication
  (let* ((store (session:make-memory-store))
         (h (make-hash-table :test #'equal))
         (env (list :headers h))
         (pre (session:ensure-session env store))
         (before (csrf:ensure-token pre)))
    (is (stringp before) "precondition: a token existed before sign-in")
    (let ((s (session:sign-in! store env :user-id 1)))
      (is (null (csrf:token s))
          "the token minted before authentication must not survive into the authenticated session")
      (let ((after (csrf:ensure-token s)))
        (is (not (equal before after))
            "and the next token minted is a different one")))))

(test a-token-held-from-before-sign-in-no-longer-verifies
  ;; The property that matters, at the check rather than at the accessor.
  (let* ((store (session:make-memory-store))
         (h (make-hash-table :test #'equal))
         (env (list :headers h))
         (pre (session:ensure-session env store))
         (stale (csrf:ensure-token pre))
         (s (session:sign-in! store env :user-id 1)))
    (csrf:ensure-token s)                       ; the authenticated session mints its own
    (is (eq :mismatch (%csrf-reason (%csrf-env :session s :header stale)))
        "a token from before the privilege change must be refused afterwards")))

;;; --- the injector (ADR-0019) ----------------------------------------------

(defun %token-in (html)
  "The value of the hidden _csrf field in HTML, or NIL. Reads the RENDERED MARKUP rather
than asking the injector what it emitted -- a sweep that consults the implementation agrees
with itself by construction."
  (let ((at (search "name=_csrf" html)))
    (when at
      (let* ((v (search "value=" html :start2 at))
             (start (+ v 6))
             (quoted (char= #\" (char html start)))
             (from (if quoted (1+ start) start))
             (end (position (if quoted #\" #\>) html :start from)))
        (subseq html from end)))))

(defun %forms-in (html)
  "Every <form ...> ... </form> block in HTML, as substrings. Independent of how we render."
  (loop with start = 0
        for open = (search "<form" html :start2 start)
        while open
        for close = (or (search "</form>" html :start2 open) (length html))
        collect (subseq html open (min (length html) (+ close 7)))
        do (setf start (1+ open))))

(defmacro %rendering ((session) &body forms)
  "Render FORMS as a request would, with SESSION's token available to the injector."
  `(let ((csrf:*token-thunk* (lambda () (csrf:ensure-token ,session))))
     (spin:with-html-string ,@forms)))

(test the-injector-puts-a-token-in-a-posting-form
  (let ((html (%rendering ((%csrf-session)) (:form :method "post" (:input :name "q")))))
    (is (stringp (%token-in html)) "a POST form must carry a token: ~S" html)
    (is (search "<input name=q>" html) "and the author's own children survive")))

(test the-injector-leaves-a-GET-form-alone
  ;; ADR-0019 hole 3, closed rather than documented: a token on a GET form lands in the
  ;; QUERY STRING on submit -- Referer, logs, browser history.
  (let ((html (%rendering ((%csrf-session)) (:form :method "get" (:input :name "q")))))
    (is (null (%token-in html)) "a GET form must NOT carry a token: ~S" html)))

(test a-form-with-no-method-is-GET-and-gets-nothing
  ;; HTML's default, which is easy to forget when reading the DSL rather than the spec.
  (let ((html (%rendering ((%csrf-session)) (:form :action "/search" (:input :name "q")))))
    (is (null (%token-in html)) "~S" html)))

(test an-htmx-form-carries-a-token-though-it-has-no-method
  ;; hx-post IS the verb in this framework's own idiom, and such a form usually has no
  ;; method attribute at all. Skipping it would leave hyperion's house style the one shape
  ;; the injector missed.
  (let ((html (%rendering ((%csrf-session)) (:form :hx-post "/x" (:button "go")))))
    (is (stringp (%token-in html)) "an hx-post form must carry a token: ~S" html)))

(test the-method-is-read-at-runtime-not-at-expansion
  (let* ((m "post")
         (html (%rendering ((%csrf-session)) (:form :method m (:span "x")))))
    (is (stringp (%token-in html)) "a computed method must still be honoured: ~S" html)))

(test outside-a-request-no-field-is-emitted
  ;; *TOKEN-THUNK* unbound means no token exists. Emitting an empty one would produce a
  ;; form that looks protected and is refused -- worse than an obviously bare one.
  (let ((html (spin:with-html-string (:form :method "post" (:input :name "q")))))
    (is (null (%token-in html)) "~S" html)))

(test nothing-is-minted-for-a-response-that-renders-no-form
  ;; The laziness ADR-0019 decision 2 asks for: a visitor who never sees a form never gets
  ;; a token, so the store does not fill with tokens minted for crawlers.
  (let ((s (%csrf-session)))
    (%rendering (s) (:div (:p "nothing to sign here")))
    (is (null (csrf:token s)) "rendering no form must mint no token")))

(test every-posting-form-on-a-page-carries-a-token-and-no-GET-form-does
  ;; THE SWEEP, with its rule written from HTML semantics rather than from the injector:
  ;; find every <form> in the rendered markup, decide from its own method attribute whether
  ;; it changes state, and require a token exactly there. A sweep that asked the injector
  ;; which forms need tokens would agree with itself.
  (let* ((html (%rendering ((%csrf-session))
                 (:div
                  (:form :method "post" :action "/a" (:input :name "x"))
                  (:form :method "get" :action "/search" (:input :name "q"))
                  (:form :hx-post "/c" (:button "go"))
                  (:form :method "put" :action "/d" (:button "save")))))
         (forms (%forms-in html)))
    (is (= 4 (length forms)) "precondition: the page really has four forms, got ~D" (length forms))
    (dolist (f forms)
      (let ((state-changing (or (search "hx-post" f) (search "hx-put" f)
                                (search "hx-patch" f) (search "hx-delete" f)
                                (and (search "method=" f)
                                     (not (search "method=get" f))))))
        (if state-changing
            (is (search "name=_csrf" f) "state-changing form has no token: ~S" f)
            (is (not (search "name=_csrf" f)) "safe form carries a token it should not: ~S" f))))))

(test the-token-the-injector-emits-is-the-one-the-check-accepts
  ;; THE TWO HALVES MUST AGREE, and neither half's own tests can show it. The injector
  ;; could emit a well-formed token from the wrong place and every test above would pass.
  (let* ((s (%csrf-session))
         (html (%rendering (s) (:form :method "post" (:input :name "q"))))
         (tok (%token-in html)))
    (is (stringp tok) "precondition: a token was emitted")
    (is (null (%csrf-reason (%csrf-env :session s :body (format nil "_csrf=~A&q=1" tok))))
        "the token the FORM carries must be the token the CHECK accepts")
    (is (eq :mismatch (%csrf-reason (%csrf-env :session s :body "_csrf=something-else&q=1")))
        "and the control: a different token is still refused")))
