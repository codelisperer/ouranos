;;;; ratelimit-tests.lisp --- hyperion/ratelimit, the limiter for authentication routes (#297).
;;;;
;;;; Every test drives the clock through *CLOCK-MS* instead of sleeping, so the times below
;;;; are exact. Requests are built by hand; nothing adds an address or a form field unless
;;;; the test names it.

(in-package #:hyperion/tests)

(def-suite ratelimit :description "Rate limiting for authentication routes." :in hyperion)
(in-suite ratelimit)

(defvar *rl-now* 0 "The time the test clock reports, in milliseconds.")

(defmacro %rl-quietly (&body forms)
  "FORMS with logging turned down: every refusal warns, which would bury the suite."
  `(unwind-protect (progn (aion/log:level! :error) ,@forms)
     (aion/log:level! :warn)))

(defmacro %with-rl-clock ((&optional (start 0)) &body body)
  `(let* ((*rl-now* ,start)
          (rl:*clock-ms* (lambda () *rl-now*)))
     (%rl-quietly ,@body)))

(defun %rl-advance (seconds) (incf *rl-now* (round (* 1000 seconds))))

(defun %rl-env (&key (method :post) (path "/sign-in") addr email)
  (let ((env (list :request-method method :path-info path
                   :headers (make-hash-table :test #'equal))))
    (when addr (setf env (list* :remote-addr addr env)))
    (when email
      (setf env (http:cache-body-string env (format nil "email=~A&password=x" email))))
    env))

(defun %rl-app ()
  "WRAP-RATE-LIMIT's app: records how many times it ran and the email it read from the
body. Returns (values app calls-box)."
  (let ((calls (list 0 nil)))
    (values (lambda (env)
              (incf (first calls))
              (setf (second calls) (http:form-param (http:body-string env) "email"))
              (list 200 (list :content-type "text/plain") (list "ok")))
            calls)))

(defun %rl-status (app env) (first (funcall app env)))

(defun %rl-by-address (&key (capacity 3) (per 60) paths)
  (rl:make-limit :sign-in-address :capacity capacity :per per
                 :key (rl:by-address) :paths paths))

(defun %rl-by-account (&key (capacity 2))
  (rl:make-limit :sign-in-account :capacity capacity :per 60
                 :key (rl:by-form-field "email")))

;;; --- the bucket -------------------------------------------------------------

(test a-bucket-allows-its-capacity-then-refuses-until-a-token-refills
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address)))))
      ;; capacity 3 per 60 s: one token every 20 s.
      (is (equal '(200 200 200)
                 (loop repeat 3 collect (%rl-status app (%rl-env :addr "10.0.0.1")))))
      (let ((refused (funcall app (%rl-env :addr "10.0.0.1"))))
        (is (= 429 (first refused)))
        (is (string= "20" (getf (second refused) :retry-after))))
      (%rl-advance 19)
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))
          "one second short of a token")
      (%rl-advance 1)
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))))))

(test a-bucket-never-refills-past-its-capacity
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address)))))
      (%rl-advance 3600)
      (is (equal '(200 200 200 429)
                 (loop repeat 4 collect (%rl-status app (%rl-env :addr "10.0.0.1"))))))))

(test retry-after-is-whole-seconds-rounded-up
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 1 :per 60)))))
      (%rl-status app (%rl-env :addr "a"))
      (%rl-advance 0.5)
      (is (string= "60" (getf (second (funcall app (%rl-env :addr "a"))) :retry-after))
          "59.5 seconds to wait is reported as 60"))))

(test each-address-has-its-own-bucket
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-address :capacity 1)))))
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1"))))
      (is (= 200 (%rl-status app (%rl-env :addr "10.0.0.2")))))))

;;; --- what the middleware applies to ------------------------------------------

(test a-get-and-another-path-are-not-counted
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 1
                                                                 :paths '("/sign-in"))))))
      (is (= 200 (%rl-status app (%rl-env :addr "a"))))
      (is (= 200 (%rl-status app (%rl-env :addr "a" :method :get)))
          "the GET that renders the form is not counted")
      (is (= 200 (%rl-status app (%rl-env :addr "a" :path "/other"))))
      (is (= 429 (%rl-status app (%rl-env :addr "a")))))))

(test a-refused-request-never-reaches-the-app
  (%with-rl-clock ()
    (multiple-value-bind (inner calls) (%rl-app)
      (let ((app (rl:wrap-rate-limit inner :limits (list (%rl-by-address :capacity 1)))))
        (funcall app (%rl-env :addr "a"))
        (funcall app (%rl-env :addr "a"))
        (funcall app (%rl-env :addr "a"))
        (is (= 1 (first calls)))))))

;;; --- account keys ------------------------------------------------------------

(test an-account-key-is-normalised
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account)))))
      (is (= 200 (%rl-status app (%rl-env :addr "a" :email "bob@x.test"))))
      (is (= 200 (%rl-status app (%rl-env :addr "b" :email "BOB@X.test"))))
      (is (= 429 (%rl-status app (%rl-env :addr "c" :email "%20Bob@x.test")))
          "case and surrounding space do not make a new bucket")
      (is (= 200 (%rl-status app (%rl-env :addr "d" :email "alice@x.test")))))))

(test the-app-can-still-read-the-body-the-key-was-read-from
  (%with-rl-clock ()
    (multiple-value-bind (inner calls) (%rl-app)
      (let ((app (rl:wrap-rate-limit inner :limits (list (%rl-by-account)))))
        (funcall app (%rl-env :addr "a" :email "bob@x.test"))
        (is (string= "bob@x.test" (second calls)))))))

(test a-request-without-the-field-is-not-counted-by-the-account-limit
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account :capacity 1)))))
      (is (equal '(200 200 200)
                 (loop repeat 3 collect (%rl-status app (%rl-env :addr "a"))))))))

(test the-refusal-is-the-same-whatever-the-account
  ;; The limiter never looks at an account store, so it cannot behave differently for an
  ;; account that exists. What an attacker can compare is the response, so assert that two
  ;; refusals for different accounts are identical.
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account :capacity 1)))))
      (funcall app (%rl-env :email "exists@x.test"))
      (funcall app (%rl-env :email "never-registered@x.test"))
      (is (equal (funcall app (%rl-env :email "exists@x.test"))
                 (funcall app (%rl-env :email "never-registered@x.test")))))))

(test address-and-account-limits-together
  ;; One client trying many accounts is stopped by the address limit; many clients trying
  ;; one account are stopped by the account limit.
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (%rl-by-address :capacity 3)
                                                 (%rl-by-account :capacity 2)))))
      (is (equal '(200 200 200 429)
                 (loop for i from 1 to 4
                       collect (%rl-status app (%rl-env :addr "one-client"
                                                        :email (format nil "u~D@x.test" i))))))
      (is (equal '(200 200 429)
                 (loop for i from 1 to 3
                       collect (%rl-status app (%rl-env :addr (format nil "client-~D" i)
                                                        :email "target@x.test"))))))))

(test reset-limit-gives-the-key-a-full-bucket
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store))
           (limit (%rl-by-account :capacity 1))
           (app (rl:wrap-rate-limit (%rl-app) :limits (list limit) :store store)))
      (funcall app (%rl-env :email "bob@x.test"))
      (is (= 429 (%rl-status app (%rl-env :email "bob@x.test"))))
      (rl:reset-limit store limit "bob@x.test")
      (is (= 200 (%rl-status app (%rl-env :email "bob@x.test")))))))

;;; --- the store's bound -------------------------------------------------------

(test the-memory-store-keeps-no-more-than-max-keys
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store :max-keys 10))
           (app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account)) :store store)))
      (loop for i from 1 to 25
            do (funcall app (%rl-env :email (format nil "u~D@x.test" i))))
      (is (<= (rl:memory-store-count store) 10)))))

(test sweeping-is-rare-when-every-request-brings-a-new-key
  ;; The review finding on #308: once the store was over MAX-KEYS with no full bucket to
  ;; drop, every new key swept and sorted the whole table, so a client sending a new email
  ;; with each request made every request pay for a sort. A sweep now goes down to nine
  ;; tenths, so 10,000 new keys into a store of 1,000 sweep about 90 times, not about 9,000.
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store :max-keys 1000))
           (app (rl:wrap-rate-limit (%rl-app) :limits (list (%rl-by-account :capacity 1))
                                    :store store)))
      (loop for i from 1 to 10000
            do (funcall app (%rl-env :email (format nil "u~D@x.test" i))))
      (let ((sweeps (hyperion/ratelimit::%sweeps store)))
        (is (<= sweeps 100) "10,000 new keys swept ~D times" sweeps)
        (is (plusp sweeps) "the store must have swept at all, or this measured nothing"))
      (is (<= (rl:memory-store-count store) 1000)))))

(test a-refused-upload-does-not-orphan-the-file-it-spilled-here-either
  ;; The review finding on #308: the refusal path deletes a multipart request's spilled
  ;; parts, as WRAP-CSRF's does, and nothing tested it. The key is read from a part, so
  ;; this also covers BY-FORM-FIELD on a multipart body.
  (%with-rl-clock ()
    (let ((http:*memory-threshold* 8)
          (calls 0))
      (flet ((upload ()
               (%mp-body "BOUND" (list (list "email" "bob@x.test")
                                       (list "f" "0123456789ABCDEF" :filename "big.bin")))))
        (let* ((app (rl:wrap-rate-limit
                     (lambda (e)
                       (incf calls)
                       ;; The app owns the spilled parts on the success path, and deletes them.
                       (let ((parts (getf e http:+multipart-parts-key+)))
                         (when (listp parts) (http:delete-parts parts)))
                       (list 200 nil nil))
                     :limits (list (%rl-by-account :capacity 1))))
               (before (length (%upload-spills))))
          (%with-mp (env tmp (upload) nil)
            (is (= 200 (first (funcall app env)))))
          (%with-mp (env tmp (upload) nil)
            (is (= 429 (first (funcall app env))) "the same email, over the limit"))
          (is (= 1 calls) "the refused request must not reach the app")
          (is (= before (length (%upload-spills)))
              "the refusal deleted what it spilled; ~D file(s) leaked"
              (- (length (%upload-spills)) before)))))))

(test the-store-drops-full-buckets-before-partly-drained-ones
  ;; A bucket that has refilled completely behaves exactly like a missing one, so dropping
  ;; it loses nothing. The drained bucket must survive the sweep and still refuse.
  (%with-rl-clock ()
    (let* ((store (rl:make-memory-store :max-keys 3))
           (app (rl:wrap-rate-limit (%rl-app)
                                    :limits (list (%rl-by-account :capacity 1)) :store store)))
      (loop for i from 1 to 2
            do (funcall app (%rl-env :email (format nil "old~D@x.test" i))))
      (%rl-advance 120)                                  ; both refill completely
      (funcall app (%rl-env :email "drained@x.test"))    ; the only bucket not full
      (funcall app (%rl-env :email "new@x.test"))        ; the fourth bucket: sweep runs
      (is (<= (rl:memory-store-count store) 3))
      (is (= 429 (%rl-status app (%rl-env :email "drained@x.test")))
          "the drained bucket must not be the one the sweep dropped"))))

;;; --- construction ------------------------------------------------------------

(test a-limit-refuses-a-nonsense-configuration
  (signals error (rl:make-limit :x :capacity 0 :per 60 :key (rl:by-address)))
  (signals error (rl:make-limit :x :capacity 5 :per 0 :key (rl:by-address)))
  (signals error (rl:make-limit :x :capacity 5 :per 60 :key nil))
  (signals error (rl:wrap-rate-limit (lambda (env) env) :limits nil)))

;;; --- a limit that counts only failures (#323) ---------------------------------------
;;;
;;; The sign-in handler below answers 303 for a successful sign-in and 200 (the form again)
;;; for a failed one. OUTCOMES is the list of what each successive request will be.

(defun %rl-sign-in-app (outcomes)
  "An app that answers each request with the next of OUTCOMES: :OK is a 303, :FAIL a 200,
:SIGNAL an error. Returns (values app calls-box)."
  (let ((calls (list 0)))
    (values (lambda (env)
              (declare (ignore env))
              (incf (first calls))
              (ecase (pop outcomes)
                (:ok (list 303 (list :location "/home") '()))
                (:fail (list 200 (list :content-type "text/plain") (list "wrong password")))
                (:signal (error "the sign-in handler failed"))))
            calls)))

(defun %rl-failures-only (&key (capacity 3) (per 60))
  (rl:make-limit :sign-in-address :capacity capacity :per per :key (rl:by-address)
                 :count-when (rl:unless-status 303)))

(defun %rl-statuses (app n &key (addr "10.0.0.1"))
  (loop repeat n collect (%rl-status app (%rl-env :addr addr))))

(test successful-sign-ins-are-not-counted-by-a-count-when-limit
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-sign-in-app (make-list 20 :initial-element :ok))
                                   :limits (list (%rl-failures-only)))))
      (is (every (lambda (s) (= 303 s)) (%rl-statuses app 20))
          "twenty members sign in from one address, over a capacity of 3"))
    (let ((app (rl:wrap-rate-limit (%rl-sign-in-app (make-list 20 :initial-element :ok))
                                   :limits (list (%rl-by-address)))))
      (is (equal '(303 303 303 429) (%rl-statuses app 4))
          "control: without :count-when the fourth sign-in is refused"))))

(test failures-empty-the-bucket-and-a-success-does-not-refill-it
  (%with-rl-clock ()
    (multiple-value-bind (inner calls) (%rl-sign-in-app '(:fail :fail :ok :fail :ok))
      (let ((app (rl:wrap-rate-limit inner :limits (list (%rl-failures-only)))))
        (is (equal '(200 200 303 200 429) (%rl-statuses app 5))
            "three failures empty a bucket of 3; the success between them costs nothing and restores nothing")
        (is (= 4 (first calls)) "the refused request never reached the handler")))))

(test a-count-when-refusal-waits-for-one-token-to-refill
  (%with-rl-clock ()
    (let* ((app (rl:wrap-rate-limit (%rl-sign-in-app '(:fail :fail :fail :ok))
                                    :limits (list (%rl-failures-only)))))
      (%rl-statuses app 3)
      (let ((refused (funcall app (%rl-env :addr "10.0.0.1"))))
        (is (= 429 (first refused)))
        (is (equal "20" (getf (second refused) :retry-after))
            "3 per 60 s refills one token every 20 s"))
      (%rl-advance 20)
      (is (= 303 (%rl-status app (%rl-env :addr "10.0.0.1"))) "and after 20 s one request passes"))))

(test a-handler-that-signals-is-counted
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-sign-in-app '(:signal :ok))
                                   :limits (list (%rl-failures-only :capacity 1)))))
      (is (typep (nth-value 1 (ignore-errors (funcall app (%rl-env :addr "10.0.0.1")))) 'simple-error))
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))
          "the attempt that signalled took the only token"))))

(test a-count-when-that-signals-counts-the-request
  (%with-rl-clock ()
    (let* ((limit (rl:make-limit :sign-in-address :capacity 1 :per 60 :key (rl:by-address)
                                 :count-when (lambda (env response)
                                               (declare (ignore env response))
                                               (error "a broken count-when"))))
           (app (rl:wrap-rate-limit (%rl-sign-in-app '(:ok :ok)) :limits (list limit))))
      (is (= 303 (%rl-status app (%rl-env :addr "10.0.0.1")))
          "the response still reaches the client")
      (is (= 429 (%rl-status app (%rl-env :addr "10.0.0.1")))
          "and the request was counted"))))

(test a-request-that-passed-the-check-is-counted-even-if-the-bucket-emptied-meanwhile
  ;; Two requests pass CHECK-TOKEN before either is counted, as concurrent requests can. Both
  ;; are debited, the bucket goes below empty, and the wait is longer by what was overdrawn.
  (let ((store (rl:make-memory-store)))
    (is (rl:check-token store "k" 1 1000 0))
    (is (rl:check-token store "k" 1 1000 0))
    (is (= 0 (rl:memory-store-count store)) "checking creates no bucket")
    (rl:debit-token store "k" 1 1000 0)
    (rl:debit-token store "k" 1 1000 0)
    (multiple-value-bind (ok wait) (rl:check-token store "k" 1 1000 0)
      (is (null ok))
      (is (= 2000 wait) "one token overdrawn: two refills before the next request"))
    (dotimes (i 5) (rl:debit-token store "k" 1 1000 0))
    (is (= 2000 (nth-value 1 (rl:check-token store "k" 1 1000 0)))
        "the overdraft stops at minus CAPACITY")))

(test a-limit-without-count-when-still-takes-its-token-before-the-handler
  ;; A mixed pair on one route: the address limit counts failures only, the account limit
  ;; counts every attempt, as the recipe for sign-in suggests.
  (%with-rl-clock ()
    (let* ((by-account (%rl-by-account :capacity 2))
           (app (rl:wrap-rate-limit (%rl-sign-in-app '(:ok :ok :ok))
                                    :limits (list (%rl-failures-only) by-account))))
      (is (equal '(303 303 429)
                 (loop repeat 3
                       collect (%rl-status app (%rl-env :addr "10.0.0.1" :email "a@x.test"))))
          "the account limit counted both successful sign-ins"))))

(defvar *rl-request-context* :unbound-here
  "Stands for a binding an app makes for every request, such as its locale or its session.")

(defun %rl-refusal-with-context (env seconds limit)
  (declare (ignore env seconds limit))
  (list 429 '() (list (princ-to-string *rl-request-context*))))

(test call-with-rate-limit-refuses-inside-the-callers-bindings
  (%with-rl-clock ()
    (let ((store (rl:make-memory-store))
          (limits (list (%rl-by-address :capacity 1))))
      (flet ((request ()
               (let ((*rl-request-context* :the-apps-context))
                 (rl:call-with-rate-limit (%rl-env :addr "10.0.0.1")
                                          (lambda (env) (declare (ignore env)) (list 200 '() '("ok")))
                                          :limits limits :store store
                                          :on-limited #'%rl-refusal-with-context))))
        (is (= 200 (first (request))))
        (is (equal '("THE-APPS-CONTEXT") (third (request)))
            "the refusal was built with the app's binding in effect")))
    (let* ((inner (rl:wrap-rate-limit (lambda (env) (declare (ignore env)) (list 200 '() '("ok")))
                                      :limits (list (%rl-by-address :capacity 1))
                                      :on-limited #'%rl-refusal-with-context))
           (app (lambda (env) (let ((*rl-request-context* :the-apps-context)) (funcall inner env)))))
      (funcall app (%rl-env :addr "10.0.0.2"))
      (is (equal '("THE-APPS-CONTEXT") (third (funcall app (%rl-env :addr "10.0.0.2"))))
          "wrap-rate-limit placed inside the binding middleware does the same"))))

(test with-rate-limit-passes-on-the-env-whose-body-was-cached
  (%with-rl-clock ()
    (let ((store (rl:make-memory-store))
          (seen nil))
      (let ((r (rl:with-rate-limit (env (%rl-env :addr "10.0.0.1" :email "bob@x.test")
                                    :limits (list (%rl-by-account)) :store store)
                 (setf seen (http:form-param (http:body-string env) "email"))
                 (list 200 '() '("ok")))))
        (is (= 200 (first r)))
        (is (equal "bob@x.test" seen) "the handler read the body the limiter had read")))))

(test call-with-rate-limit-needs-a-store-and-count-when-must-be-a-function
  (is (typep (nth-value 1 (ignore-errors
                           (rl:call-with-rate-limit (%rl-env :addr "10.0.0.1") #'identity
                                                    :limits (list (%rl-by-address)))))
             'error))
  (is (typep (nth-value 1 (ignore-errors
                           (rl:make-limit :x :capacity 1 :per 1 :key (rl:by-address)
                                             :count-when 303)))
             'error)))

(test unless-status-counts-everything-but-the-listed-statuses
  (let ((f (rl:unless-status 302 303)))
    (is (not (funcall f '() '(303 () ()))))
    (is (not (funcall f '() '(302 () ()))))
    (is (funcall f '() '(200 () ())))
    (is (funcall f '() '(401 () ())))))
