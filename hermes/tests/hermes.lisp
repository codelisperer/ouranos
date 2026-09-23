;;;; tests/hermes.lisp --- fiveam suite for hermes (delivery + inbound).
;;;;
;;;; No network: the SendGrid/Twilio HTTP paths aren't exercised here (that needs live creds);
;;;; we test the neutral protocol, env-based provider selection, the dev transport (renders,
;;;; never sends), the failure protocol (ensure-2xx), and the inbound Twilio webhook's
;;;; signature verification (valid accepted, forged rejected) + neutral event + emit.

(cl:defpackage #:hermes/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:h #:hermes) (#:in #:hermes/inbound))
  (:export #:run-tests))
(cl:in-package #:hermes/tests)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ignore-errors (require :sb-posix)))

(def-suite hermes :description "hermes delivery + inbound.")
(defun run-tests () (run! 'hermes))
(in-suite hermes)

;;; --- writing the environment, without a read-time dependency on sb-posix ---
;;;
;;; SBCL's Windows sb-posix is thinner than the POSIX one. A literal `sb-posix:setenv'
;;; is resolved by the READER, so on a build lacking that symbol this file dies with a
;;; package error and takes the whole suite with it — and the gate now runs every system
;;; in its own image and fails on any warning, so that is a hard failure rather than
;;; something you notice and route around. Look the symbol up at RUNTIME instead, so the
;;; blast radius is the tests that need it, which then skip and say why.
;;;
;;; No Lisp-side fallback is possible: the code under test reads `uiop:getenv', i.e. the
;;; real C environment. Nor is `(setf uiop:getenv)' one — it expands to the same call.
;;; Provider selection also distinguishes "" from unset, so unsetenv must be the real one.

(defun %env-fn (name)
  "The SB-POSIX function NAME, or NIL when this build has no such thing."
  (let* ((package (find-package "SB-POSIX"))
         (symbol (and package (find-symbol name package))))
    (and symbol (fboundp symbol) symbol)))

(defun env-writable-p ()
  "True when this build can mutate the C environment that `uiop:getenv' reads."
  (and (%env-fn "SETENV") (%env-fn "UNSETENV") t))

(defun set-env (name value) (funcall (%env-fn "SETENV") name value 1))
(defun unset-env (name) (funcall (%env-fn "UNSETENV") name))

(defmacro with-env (bindings &body body)
  "Set env vars for BODY, restoring after. BINDINGS: ((\"NAME\" value-or-nil) ...) — NIL unsets.
Skips when the build cannot write the environment — see ENV-WRITABLE-P."
  (let ((saves (gensym)))
    `(if (not (env-writable-p))
         (skip "no sb-posix:setenv in this build — env selection is unexercised here")
         (let ((,saves (mapcar (lambda (b) (cons (car b) (uiop:getenv (car b)))) ',bindings)))
           (unwind-protect
                (progn ,@(mapcar (lambda (b)
                                   (if (second b)
                                       `(set-env ,(first b) ,(second b))
                                       `(ignore-errors (unset-env ,(first b)))))
                                 bindings)
                       ,@body)
             (dolist (s ,saves)
               (if (cdr s) (set-env (car s) (cdr s))
                   (ignore-errors (unset-env (car s))))))))))

;;; --- protocol -------------------------------------------------------------
(test unsupported-message-signalled
  ;; a bare email-provider asked to deliver an SMS hits the default method
  (signals h:unsupported-message
    (h:deliver (make-instance 'h:email-provider) (h:make-sms :to "+15550000000" :text "hi"))))

(test env-selection-defaults
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_EMAIL_IMPL" nil) ("HERMES_SMS_IMPL" nil))
    (is (typep (h:email-provider-from-env) 'h:sendgrid))
    (is (typep (h:sms-provider-from-env) 'h:twilio))))

(test env-transport-dev-overrides-both
  (with-env (("HERMES_TRANSPORT" "dev"))
    (is (typep (h:email-provider-from-env) 'h:dev-transport))
    (is (typep (h:sms-provider-from-env) 'h:dev-transport)))
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_EMAIL_IMPL" "dev"))
    (is (typep (h:email-provider-from-env) 'h:dev-transport))))

;;; --- dev transport --------------------------------------------------------
(test dev-transport-renders-not-sends
  (let* ((out (make-string-output-stream))
         (p (h:make-dev-transport :stream out))
         (r (h:deliver p (h:make-email :to "a@x.io" :from "b@y.io" :subject "Verify"
                                       :text "click http://app/verify/abc123"))))
    (is (eq :dev (h:delivery-result-provider r)))
    (is (eq :logged (h:delivery-result-status r)))
    (let ((s (get-output-stream-string out)))
      (is (search "a@x.io" s))
      (is (search "http://app/verify/abc123" s) "the link must be visible in dev output"))))

(test send-uses-env-provider
  (with-env (("HERMES_TRANSPORT" "dev"))
    (let ((*standard-output* (make-broadcast-stream)))          ; swallow the dev render
      (is (eq :dev (h:delivery-result-provider
                    (h:send (h:make-email :to "a@x" :from "b@y" :subject "S" :text "T")))))
      (is (eq :dev (h:delivery-result-provider
                    (h:send (h:make-sms :to "+15551230000" :from "+15559990000" :text "hi"))))))))

;;; --- the boundary with aion/http-client (pre-publication issue 202) ----------------------------
;;;
;;; The HTTP client moved to aion, and with it the ensure-2xx behaviour this file used to
;;; test directly -- covered now by aion/http-client/tests, where the code lives.
;;;
;;; What is hermes' OWN responsibility after the move is the translation: the shared client
;;; signals HTTP-ERROR, which is deliberately not a messaging condition, and DELIVER's
;;; contract promises DELIVERY-FAILURE. AS-DELIVERY is the seam that restores the meaning,
;;; and it is the thing that would silently break the contract if it regressed.

(test a-transport-failure-arrives-as-a-delivery-failure
  ;; DELIVER promises DELIVERY-FAILURE. A caller must not have to know that an HTTP client
  ;; sits underneath, nor catch a condition from a different framework.
  (signals h:delivery-failure
    (hermes::as-delivery :sendgrid
      (error 'aion/http-client:http-error :detail "transport error: connection refused"))))

(test the-provider-and-status-survive-the-translation
  ;; The status and the provider's own body are what make a failure actionable; losing them
  ;; in translation would turn a legible refusal back into an opaque one.
  (handler-case
      (progn (hermes::as-delivery :twilio
               (error 'aion/http-client:http-error :status 400 :body "invalid To number"))
             (fail "should have signalled"))
    (h:delivery-failure (c)
      (is (eq :twilio (h:delivery-failure-provider c)))
      (is (= 400 (h:delivery-failure-status c)))
      (is (search "invalid To number" (h:delivery-failure-detail c))
          "the provider's explanation must survive"))))

(test a-successful-call-passes-through-untouched
  (is (= 42 (hermes::as-delivery :sendgrid 42))))

;;; --- inbound: Twilio webhook signature ------------------------------------
(defparameter +tok+ "test-auth-token-0123456789")
(defparameter +url+ "https://app.example/hooks/twilio/sms")
(defparameter +params+ '(("From" . "+15551234567") ("To" . "+15557654321")
                         ("Body" . "hello there") ("MessageSid" . "SM0123")))

(test twilio-signature-accept-and-reject
  (let ((sig (hermes/inbound::%twilio-signature +url+ +params+ +tok+)))
    (is (in:verify-twilio-signature +url+ +params+ sig :auth-token +tok+))            ; valid
    (is (not (in:verify-twilio-signature +url+ +params+ "forged==" :auth-token +tok+))) ; forged
    (is (not (in:verify-twilio-signature +url+ +params+ sig :auth-token "wrong-token"))) ; wrong key
    (is (not (in:verify-twilio-signature +url+ +params+ nil :auth-token +tok+)))))       ; missing

(test twilio-webhook-emits-on-valid-rejects-forged
  (let* ((sig (hermes/inbound::%twilio-signature +url+ +params+ +tok+))
         (received '())
         (sub (in:subscribe (lambda (m) (push m received)))))
    (unwind-protect
         (progn
           (let ((msg (in:twilio-webhook +url+ +params+ sig :auth-token +tok+)))
             (is (string= "+15551234567" (in:inbound-message-from msg)))
             (is (string= "hello there" (in:inbound-message-body msg)))
             (is (eq :twilio (in:inbound-message-provider msg)))
             (is (string= "SM0123" (in:inbound-message-provider-id msg)))
             (is (= 1 (length received)) "valid webhook emits to subscribers"))
           (signals in:signature-required
             (in:twilio-webhook +url+ +params+ "forged==" :auth-token +tok+))
           (is (= 1 (length received)) "a forged webhook does not emit"))
      (in:unsubscribe sub))))

(test parse-twilio-inbound-normalizes
  (let ((m (in:parse-twilio-inbound '(("From" . "15551112222") ("To" . "+15553334444")
                                      ("Body" . "b") ("MessageSid" . "SMx")))))
    (is (string= "+15551112222" (in:inbound-message-from m)) "bare digits get a leading +")
    (is (string= "+15553334444" (in:inbound-message-to m)))
    (is (string= "SMx" (in:inbound-message-provider-id m)))))

(test twiml-message-escapes
  (let ((x (in:twiml-message "a & b < c > d \"e\"")))
    (is (search "<Response><Message>" x))
    (is (search "&amp;" x))
    (is (search "&lt;" x))
    (is (search "&quot;" x))))
