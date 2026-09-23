;;;; session-tests.lisp --- hyperion/session (store + cookie seam + dev mgmt).

(in-package #:hyperion/tests)

(def-suite session :description "Cookie-based HTTP sessions." :in hyperion)
(in-suite session)

(defun %env (&optional cookie)
  "A minimal Clack env carrying an optional Cookie header."
  (let ((h (make-hash-table :test 'equal)))
    (when cookie (setf (gethash "cookie" h) cookie))
    (list :headers h)))

(defun %cookie-for (id)
  (format nil "~A=~A" session:*cookie-name* id))

;;; --- minting + cookie -----------------------------------------------------
(test new-session-mints-id-and-cookie
  (let ((store (session:make-memory-store)))
    (multiple-value-bind (s set-cookie) (session:ensure-session (%env) store)
      (is (session:session-p s))
      (is (plusp (length (session:session-id s))))
      (is (stringp set-cookie))
      (is (search (session:session-id s) set-cookie))     ; cookie carries the id
      (is (search "HttpOnly" set-cookie))
      (is (= 1 (session:store-count store))))))

(test returning-cookie-reuses-session
  (let ((store (session:make-memory-store)))
    (let ((s1 (session:ensure-session (%env) store)))
      (multiple-value-bind (s2 sc2)
          (session:ensure-session (%env (%cookie-for (session:session-id s1))) store)
        (is (eq s1 s2))            ; same session object
        (is (null sc2))            ; no new cookie issued
        (is (= 1 (session:store-count store)))))))

(test unknown-cookie-mints-new
  (let ((store (session:make-memory-store)))
    (multiple-value-bind (s sc) (session:ensure-session (%env (%cookie-for "deadbeef")) store)
      (is (session:session-p s))
      (is (stringp sc))                                    ; a fresh cookie
      (is (not (string= "deadbeef" (session:session-id s)))))))

(test no-create-returns-nil
  (let ((store (session:make-memory-store)))
    (multiple-value-bind (s sc) (session:ensure-session (%env) store :create nil)
      (is (null s))
      (is (null sc))
      (is (= 0 (session:store-count store))))))

(test ids-are-distinct
  (let ((store (session:make-memory-store)))
    (let ((a (session:ensure-session (%env) store))
          (b (session:ensure-session (%env) store)))
      (is (not (string= (session:session-id a) (session:session-id b))))
      (is (= 2 (session:store-count store))))))

;;; --- the data bag ---------------------------------------------------------
(test session-data-roundtrips
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store)))
    (session:session-set s :conversation "abc123")
    (is (string= "abc123" (session:session-get s :conversation)))
    (is (eq :none (session:session-get s :missing :none)))
    (is (equal '(:conversation) (session:session-keys s)))
    (session:reset-session s)
    (is (null (session:session-keys s)))
    (is (string= (session:session-id s)                    ; id survives a reset
                 (session:session-id (session:store-ref store (session:session-id s)))))))

;;; --- dev/REPL management --------------------------------------------------
(test kill-and-list-sessions
  (let ((store (session:make-memory-store)))
    (let ((a (session:ensure-session (%env) store))
          (b (session:ensure-session (%env) store)))
      (is (= 2 (length (session:sessions store))))
      (is (session:kill-session store a))                  ; by object
      (is (= 1 (session:store-count store)))
      (is (null (session:store-ref store (session:session-id a))))
      (is (session:kill-session store (session:session-id b)))  ; by id
      (is (= 0 (session:store-count store))))))

(test kill-sessions-with-predicate
  (let ((store (session:make-memory-store)))
    (let ((keep (session:ensure-session (%env) store)))
      (session:session-set keep :keep t)
      (session:ensure-session (%env) store)
      (session:ensure-session (%env) store)
      ;; evict everything WITHOUT a :keep flag
      (let ((n (session:kill-sessions
                store (lambda (s) (not (session:session-get s :keep))))))
        (is (= 2 n))
        (is (= 1 (session:store-count store)))
        (is (eq keep (session:store-ref store (session:session-id keep))))))))

(test session-summary-shape
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store)))
    (session:session-set s :x 1)
    (let ((sum (session:session-summary s)))
      (is (string= (session:session-id s) (getf sum :id)))
      (is (integerp (getf sum :created)))
      (is (equal '(:x) (getf sum :keys))))))

;;; --- rotation: the privilege-boundary primitive (#207) --------------------
;;;
;;; The defect these guard is not a missing feature but an INVITING WRONG ANSWER:
;;; RESET-SESSION sits where rotation should be, reads like fixation defence, and keeps
;;; the id. So the pair of tests that matters most is "rotate changes it" next to
;;; "reset does not" -- the second one documents the trap by failing if it ever moves.

(defun %cookie-id (set-cookie)
  "The session id out of a Set-Cookie header value."
  (let* ((prefix (concatenate 'string session:*cookie-name* "="))
         (start (+ (search prefix set-cookie) (length prefix)))
         (end (or (position #\; set-cookie :start start) (length set-cookie))))
    (subseq set-cookie start end)))

(test rotate-session-changes-the-id
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store))
         (before (session:session-id s)))
    (session:rotate-session store s)
    (is (not (string= before (session:session-id s))))
    (is (plusp (length (session:session-id s))))))

(test rotate-session-keeps-the-data
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store)))
    (session:session-set s :user-id 42)
    (session:rotate-session store s)
    (is (= 42 (session:session-get s :user-id))
        "rotation is a new credential, not a new session -- the bag survives")))

(test rotate-session-rekeys-the-store
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store))
         (before (session:session-id s)))
    (session:rotate-session store s)
    (is (null (session:store-ref store before))
        "the OLD id must stop resolving -- an id that still works was not rotated")
    (is (eq s (session:store-ref store (session:session-id s))))
    (is (= 1 (session:store-count store)) "re-keyed, not duplicated")))

(test rotate-session-returns-a-cookie-for-the-new-id
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store)))
    (multiple-value-bind (same set-cookie) (session:rotate-session store s)
      (is (eq s same))
      (is (stringp set-cookie))
      (is (string= (session:session-id s) (%cookie-id set-cookie))))))

(test rotate-session-mutates-in-place-so-references-stay-live
  ;; The reason the id slot is not :read-only. A caller that bound the session before
  ;; rotating -- the env does exactly this -- must still be writing into the stored
  ;; session afterwards, not into an orphan.
  (let* ((store (session:make-memory-store))
         (held (session:ensure-session (%env) store)))
    (session:rotate-session store held)
    (session:session-set held :written-after :rotation)
    (is (eq :rotation
            (session:session-get (session:store-ref store (session:session-id held))
                                 :written-after)))))

(test rotate-session-honours-cookie-options
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store)))
    (multiple-value-bind (ignored set-cookie)
        (session:rotate-session store s :secure t :max-age 60)
      (declare (ignore ignored))
      (is (search "; Secure" set-cookie))
      (is (search "Max-Age=60" set-cookie)))))

(test reset-session-keeps-the-id-and-that-is-the-trap
  ;; Not a wish -- the documented behaviour. If this ever starts failing, RESET-SESSION
  ;; has silently become rotation and its docstring is now a lie.
  (let* ((store (session:make-memory-store))
         (s (session:ensure-session (%env) store))
         (before (session:session-id s)))
    (session:session-set s :user-id 7)
    (session:reset-session s)
    (is (string= before (session:session-id s)))
    (is (null (session:session-get s :user-id)))))

;;; --- the middleware: a Set-Cookie a handler cannot drop (#207) ------------

(defun %wrapped (store handler &rest options)
  (apply #'session:wrap-session handler store options))

(defun %ok (env)
  (declare (ignore env))
  (list 200 '(:content-type "text/plain") (list "ok")))

(test wrap-session-puts-the-session-on-the-env
  (let* ((store (session:make-memory-store))
         (seen nil)
         (app (%wrapped store (lambda (env)
                                (setf seen (session:request-session env))
                                (%ok env)))))
    (funcall app (%env))
    (is (session:session-p seen))
    (is (eq seen (session:store-ref store (session:session-id seen))))))

(test wrap-session-emits-set-cookie-on-a-mint
  (let* ((store (session:make-memory-store))
         (app (%wrapped store #'%ok))
         (response (funcall app (%env))))
    (let ((sc (getf (second response) :set-cookie)))
      (is (stringp sc))
      (is (session:store-ref store (%cookie-id sc))))))

(test wrap-session-is-quiet-for-a-returning-browser
  (let* ((store (session:make-memory-store))
         (app (%wrapped store #'%ok))
         (r1 (funcall app (%env)))
         (id (%cookie-id (getf (second r1) :set-cookie)))
         (r2 (funcall app (%env (%cookie-for id)))))
    (is (null (getf (second r2) :set-cookie))
        "nothing changed, so nothing is owed")
    (is (= 1 (session:store-count store)))))

(test a-handler-that-ignores-the-session-entirely-still-persists
  ;; The #207 second defect, from the other side. With ENSURE-SESSION the app must
  ;; remember to emit a second value; forget, and every request mints afresh while each
  ;; handler still reads correctly. Here the handler is given no opportunity to forget.
  (let* ((store (session:make-memory-store))
         (app (%wrapped store #'%ok))
         (r1 (funcall app (%env)))
         (id (%cookie-id (getf (second r1) :set-cookie))))
    (funcall app (%env (%cookie-for id)))
    (funcall app (%env (%cookie-for id)))
    (is (= 1 (session:store-count store))
        "three requests, one session -- the cookie was never the app's to drop")))

(test wrap-session-emits-the-new-cookie-after-a-rotation
  (let* ((store (session:make-memory-store))
         (app (%wrapped store #'%ok))
         (r1 (funcall app (%env)))
         (id (%cookie-id (getf (second r1) :set-cookie)))
         (rotating (%wrapped store (lambda (env)
                                     (session:rotate-session
                                      store (session:request-session env))
                                     (%ok env))))
         (response (funcall rotating (%env (%cookie-for id)))))
    (let ((sc (getf (second response) :set-cookie)))
      (is (stringp sc) "a rotation inside the handler still owes the browser a cookie")
      (is (not (string= id (%cookie-id sc))))
      (is (session:store-ref store (%cookie-id sc)))
      (is (null (session:store-ref store id))))))

(test wrap-session-applies-its-cookie-options-to-a-rotation
  (let* ((store (session:make-memory-store))
         (rotating (%wrapped store (lambda (env)
                                     (session:rotate-session
                                      store (session:request-session env))
                                     (%ok env))
                             :secure t))
         (response (funcall rotating (%env))))
    (is (search "; Secure" (getf (second response) :set-cookie))
        ":secure must hold for the rotated cookie too, not just the minted one")))

(test wrap-session-signals-rather-than-dropping-the-cookie
  ;; Passing an unusable response through would put the silent failure back exactly
  ;; where it was removed from.
  (let* ((store (session:make-memory-store))
         (app (%wrapped store (lambda (env) (declare (ignore env)) :not-a-response))))
    (signals session:session-cookie-not-attachable (funcall app (%env)))))

;;; --- SIGN-IN!: the privilege change, rotation included (#282) --------------
;;;
;;; The reported incident, reproduced in both directions. The control below runs the
;;; pattern the consuming app actually shipped and shows the donated id surviving; the
;;; test above it shows SIGN-IN! killing it. Without the control, "the donated id is
;;; gone" proves nothing -- it would also pass if the donation had never worked.

(test the-shipped-pattern-leaves-a-donated-id-alive-and-authenticated
  ;; THE CONTROL. ensure-session + session-set is what reads correctly, works, passes
  ;; tests, and is wrong. If this test ever goes green-by-failing, the attack it models
  ;; stopped being possible and the test below is no longer evidence of anything.
  (let* ((store (session:make-memory-store))
         ;; The attacker signs in AS THEMSELVES to mint a STORE-VALID id. This is the move
         ;; the textbook version misses: an INVENTED cookie is ignored by this store, so
         ;; anyone reasoning about "attacker plants a cookie" correctly concludes it fails.
         (donated (session:session-id (session:ensure-session (%env) store)))
         (env (%env (%cookie-for donated))))
    (let ((s (session:ensure-session env store)))     ; what the app wrote
      (session:session-set s :user-id 42))
    (let ((reached (session:store-ref store donated)))
      (is (session:session-p reached)
          "the donated id still resolves after sign-in")
      (is (equal 42 (session:session-get reached :user-id))
          "and it now reaches an AUTHENTICATED session -- the attacker is signed in as the victim"))))

(test sign-in-kills-the-donated-id
  (let* ((store (session:make-memory-store))
         (donated (session:session-id (session:ensure-session (%env) store)))
         (env (%env (%cookie-for donated))))
    (is (session:session-p (session:store-ref store donated))
        "precondition: the donated id resolves BEFORE sign-in, or this test asserts nothing")
    (let ((s (session:sign-in! store env :user-id 42)))
      (is (not (equal donated (session:session-id s)))
          "the post-sign-in id must not be the one the request arrived with")
      (is (null (session:store-ref store donated))
          "and the donated id must no longer resolve -- the attacker's cookie is dead")
      (is (equal 42 (session:session-get s :user-id))
          "while the session that authenticated keeps its data"))))

(test sign-in-rotates-even-when-the-request-carried-no-session
  ;; No branch through here may skip the rotation.
  (let* ((store (session:make-memory-store))
         (env (%env)))
    (multiple-value-bind (s set-cookie) (session:sign-in! store env :user-id 7)
      (is (session:session-p s))
      (is (plusp (length (session:session-id s))))
      (is (search (session:session-id s) set-cookie)
          "the returned Set-Cookie names the id the session actually has")
      (is (equal 7 (session:session-get s :user-id))))))

(test sign-in-stores-every-pair-it-is-given
  (let* ((store (session:make-memory-store))
         (s (session:sign-in! store (%env) :user-id 1 :role :admin :tenant "acme")))
    (is (equal 1 (session:session-get s :user-id)))
    (is (eq :admin (session:session-get s :role)))
    (is (equal "acme" (session:session-get s :tenant)))))

(test sign-in-under-wrap-session-emits-the-cookie-without-the-handler-returning-it
  ;; The middleware detects the id change, so an app never handles the header. The handler
  ;; here deliberately DISCARDS sign-in!'s second value, which is the mistake #207 is about.
  (let* ((store (session:make-memory-store))
         (app (lambda (env)
                (session:sign-in! store env :user-id 99)     ; second value dropped on purpose
                (list 200 (list :content-type "text/plain") (list "ok"))))
         (wrapped (session:wrap-session app store))
         (response (funcall wrapped (%env))))
    (let ((set-cookie (getf (second response) :set-cookie)))
      (is (stringp set-cookie) "the middleware emitted a Set-Cookie the handler dropped")
      (is (search session:*cookie-name* set-cookie)))))
