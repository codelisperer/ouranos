;;;; timeouts.lisp --- how long a send waits, and where that figure comes from (#1077)
;;;;
;;;; These tests need no provider account and no network. They point a backend at a local socket
;;;; that completes the TCP handshake and then never sends a byte, which is what a provider
;;;; behind an overloaded proxy looks like: the request goes out and nothing comes back. A
;;;; refused port would test the wrong thing, because the connection fails at once whether a read
;;;; timeout exists or not.
;;;;
;;;; WHAT THESE CANNOT TEST, and why the tests are shaped the way they are. #1077 was filed
;;;; believing that a send with no timeout waits for ever, so the test asked for was "it hangs
;;;; without the timeout". It does not hang: AION/HTTP-CLIENT passes a timeout to dexador only
;;;; when one is set, and dexador's own default is ten seconds, so an unset timeout has always
;;;; meant ten. Measured: both timeouts NIL gives 10.0 seconds. There is therefore no hang to
;;;; demonstrate, and a test asserting one would have been asserting something false.
;;;;
;;;; What is left to establish is the property that actually matters: the elapsed time follows
;;;; the setting, and a figure hermes sets wins over the one in the dependency. That is a ladder
;;;; of short timeouts, each measured. The values are kept small so the suite does not spend ten
;;;; seconds proving a default.

(in-package #:hermes/tests)

(in-suite hermes)

(defmacro with-silent-server ((port-var) &body body)
  "Run BODY with PORT-VAR bound to a port on 127.0.0.1 that accepts TCP connections and never
sends a byte. The listener is closed on the way out, including on a non-local exit."
  (let ((listener (gensym "LISTENER")))
    `(let ((,listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
       (unwind-protect
            (progn
              (setf (sb-bsd-sockets:sockopt-reuse-address ,listener) t)
              (sb-bsd-sockets:socket-bind ,listener #(127 0 0 1) 0)
              (sb-bsd-sockets:socket-listen ,listener 16)
              (let ((,port-var (nth-value 1 (sb-bsd-sockets:socket-name ,listener))))
                ,@body))
         (sb-bsd-sockets:socket-close ,listener)))))

(defun %elapsed-seconds (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun %an-email ()
  (h:make-email :to "to@example.com" :from "from@example.com" :subject "s" :text "t"))

(defun %an-sms ()
  (h:make-sms :to "+15005550007" :text "t"))

(defun %time-a-send (thunk)
  "Seconds THUNK took to fail, asserting that it did fail.

The assertion is the point, and the first version of this helper did not make it: both branches
of its HANDLER-CASE returned NIL, so a send that RETURNED NORMALLY was timed and reported like
one that failed, and every elapsed-time assertion downstream would have passed. The docstring
claimed the check that the code did not perform. Found in review of #1077.

Every caller sends to a socket that accepts the connection and never answers, so a normal return
means the backend reported success for a message no provider ever acknowledged, which is a worse
defect than any timing error this file is looking for."
  (let ((start (get-internal-real-time))
        (failed nil))
    (handler-case (funcall thunk)
      (h:delivery-failure () (setf failed t)))
    (let ((elapsed (%elapsed-seconds start)))
      (is-true failed
               "a send to a server that never answers must fail; it returned normally after ~,2Fs"
               elapsed)
      elapsed)))

(defparameter +dexador-default-timeout+ 10
  "The read timeout dexador applies when none is passed (`*default-read-timeout*' in its
src/util.lisp). The tests below assert that a send gives up WELL UNDER this, because that is what
distinguishes a timeout hermes set from the one the dependency would have used anyway.")

(defun %is-the-setting-in-force (seconds elapsed what)
  "Assert that a send with a READ-TIMEOUT of SECONDS took ELAPSED seconds because of that
setting: at least SECONDS, since a send that failed instantly failed for some other reason and
would satisfy a test that only looked for a failure, and comfortably under dexador's own default,
since that is what would be in force if the setting were dropped.

The upper bound is not SECONDS plus a small margin, which is what this test asserted first.
Windows took 4.00 seconds to honour a 1-second read timeout -- measured on CI, where the bound
was (+ SECONDS 3) and the run failed by milliseconds. The platform adds overhead of its own, and
the relationship between a small setting and the elapsed time is not something this test should
claim to know. What it can claim on every platform is the part that matters: the send ended
because hermes named a number, not because dexador did."
  (is (<= seconds elapsed)
      "~A: a read timeout of ~Ds gave up after ~,2Fs, which is less than the timeout itself"
      what seconds elapsed)
  (is (< elapsed (1- +dexador-default-timeout+))
      "~A: a read timeout of ~Ds gave up after ~,2Fs, so hermes's setting is in force rather than dexador's ~Ds"
      what seconds elapsed +dexador-default-timeout+))

(test a-sendgrid-read-timeout-is-the-one-hermes-was-given
  "#1077: a send gives up on hermes's timeout rather than on the one dexador would have applied.
See %IS-THE-SETTING-IN-FORCE for what is asserted and why the upper bound is dexador's default
rather than the setting plus a margin."
  (with-silent-server (port)
    (dolist (seconds '(1 2))
      (let* ((p (h:make-sendgrid :api-key "k" :read-timeout seconds :connect-timeout 2
                                 :endpoint (format nil "http://127.0.0.1:~D/v3/mail/send" port)))
             (elapsed (%time-a-send (lambda () (h:deliver p (%an-email))))))
        (%is-the-setting-in-force seconds elapsed "sendgrid")))))

(test a-twilio-read-timeout-is-the-one-hermes-was-given
  "#1077, the same for Twilio, whose endpoint is redirected with :API-BASE."
  (with-silent-server (port)
    (dolist (seconds '(1 2))
      (let* ((p (h:make-twilio :account-sid "AC-test" :auth-token "t" :from "+15005550006"
                               :read-timeout seconds :connect-timeout 2
                               :api-base (format nil "http://127.0.0.1:~D/2010-04-01" port)))
             (elapsed (%time-a-send (lambda () (h:deliver p (%an-sms))))))
        (%is-the-setting-in-force seconds elapsed "twilio")))))

(test a-shorter-send-timeout-gives-up-no-later-than-a-longer-one
  "A second look at the same property, from the other direction: if something other than the
setting were ending these sends, two different settings would produce the same elapsed time.

STRICT ORDERING IS ASSERTED ONLY WHERE THE PLATFORM CAN SHOW IT. Windows took 4.00 seconds to
honour a 1-second read timeout, so the elapsed time there is the setting plus overhead of the
platform's own, and whether a 1-second and a 2-second timeout are distinguishable at that
granularity is not something this test knows in advance. When the two measurements are within a
quarter of a second of each other it says so and skips, rather than failing on a platform
property or passing on a comparison that could not have failed. Nothing is lost by that: if the
setting were being ignored, both sends would take dexador's ten seconds and the assertions in
the two tests above would fail."
  (with-silent-server (port)
    (flet ((seconds-for (timeout)
             (let ((p (h:make-sendgrid :api-key "k" :read-timeout timeout :connect-timeout 2
                                       :endpoint (format nil "http://127.0.0.1:~D/x" port))))
               (%time-a-send (lambda () (h:deliver p (%an-email)))))))
      (let* ((quick (seconds-for 1))
             (slower (seconds-for 2))
             (gap (- slower quick)))
        ;; BOTH, asserted separately. An earlier version of this said "both" and checked only
        ;; the slower one, which is a claim the assertion did not make: without the strict
        ;; ordering below -- which is skipped where the platform cannot show it -- nothing then
        ;; said the quicker send was under the default either.
        (is (< quick (1- +dexador-default-timeout+))
            "the 1s send is under dexador's ~Ds default: ~,2Fs" +dexador-default-timeout+ quick)
        (is (< slower (1- +dexador-default-timeout+))
            "and the 2s send is too: ~,2Fs" slower)
        ;; THE ABSOLUTE GAP. With a signed one, a REVERSED pair -- the very thing this assertion
        ;; exists to catch -- had a negative gap, satisfied (<= gap 0.25) and skipped, so the
        ;; check could not fail in the direction that mattered. Measured: quick=2.0 slower=1.0
        ;; gives gap -1.0 and skipped (the review of #1094).
        (if (<= (abs gap) 0.25)
            (skip "1s took ~,2Fs and 2s took ~,2Fs, a gap of ~,2Fs: this platform's timing is too coarse to tell the two settings apart, and the bound above is what carries the claim here"
                  quick slower gap)
            (is (< quick slower)
                "1s gave up after ~,2Fs and 2s after ~,2Fs, so the elapsed time follows the setting"
                quick slower))))))

(test the-send-timeout-defaults-are-ten-and-settable
  "#1077: both defaults are 10, which is what dexador already did, so nothing changes for an app
that sets nothing. The point of the settings is that the figure is hermes's and written down."
  (is (eql 10 h:*send-connect-timeout*))
  (is (eql 10 h:*send-read-timeout*))
  (let ((p (h:make-sendgrid :api-key "k")))
    (is (eql 10 (h:sendgrid-connect-timeout p)))
    (is (eql 10 (h:sendgrid-read-timeout p))))
  (let ((p (h:make-twilio :account-sid "a" :auth-token "t")))
    (is (eql 10 (h:twilio-connect-timeout p)))
    (is (eql 10 (h:twilio-read-timeout p))))
  (is (eql 3 (h:sendgrid-read-timeout (h:make-sendgrid :api-key "k" :read-timeout 3))))
  (is (eql 4 (h:twilio-connect-timeout (h:make-twilio :account-sid "a" :auth-token "t"
                                                      :connect-timeout 4))))
  ;; A provider's slot follows the special when the special is what an app changed.
  (let ((h:*send-read-timeout* 7))
    (is (eql 7 (h:sendgrid-read-timeout (h:make-sendgrid :api-key "k")))
        "the special is the default, so changing it changes providers made afterwards")))

(defun %api-base-refusal (base)
  "The report of the CONFIGURATION-ERROR that refusing BASE produced, or NIL if it was accepted."
  (handler-case (progn (h:make-twilio :account-sid "ACx" :auth-token "t" :api-base base) nil)
    (h:configuration-error (e) (princ-to-string e))))

(test a-twilio-api-base-is-refused-for-the-reason-it-deserves
  "#1077 and the reviews of #1084 and #1089. Every Twilio request carries the account SID and
auth token in an Authorization header, so where a request goes is where those go.

EACH CASE ASSERTS WHICH CHECK REFUSED IT, not merely that something did. A list of bases that all
signal the same condition would pass if one check were doing all the work, and that is how a
refusal written for one reason comes to be relied on for another (the review of #1084).

NO NETWORK: every host here is an IP literal or a name under .invalid, which cannot resolve, so
nothing in this test depends on DNS answering. Two earlier cases used example.com and
api.twilio.com, which did resolve, contradicting this file's own header."
  (dolist (case '(("https://AC1:pw@api.example.invalid/x" . "user name or password")
                  ("http://user:pw@host.invalid" . "user name or password")
                  ("http://[::1]@host.invalid/x" . "user name or password")
                  ("https://[::1]@127.0.0.1/x" . "user name or password")
                  ("evil.invalid://127.0.0.1" . "The scheme is")
                  ("api.twilio.invalid/2010-04-01" . "The scheme is")
                  ("//host.invalid/x" . "The scheme is")
                  ("https://api.example.invalid/x?q=1" . "query or a fragment")
                  ("https://api.example.invalid/x#f" . "query or a fragment")
                  ("http://[::1]:4010" . "bracketed IPv6")
                  ;; Refused by the locality rule rather than by a check of its own: a
                  ;; leading-zero spelling is not local, because PARSE-ADDRESS and the system
                  ;; resolver can read it differently (#1082 moved that into LOCAL-HOST-P).
                  ("http://010.0.0.1:4010" . "in the clear")
                  ("http://8.8.8.8" . "in the clear")
                  ("http://host.invalid" . "in the clear")))
    (let ((report (%api-base-refusal (car case))))
      (is-true report "~S is refused" (car case))
      (is-true (and report (search (cdr case) report))
               "~S is refused for ~S, and the report says so: ~A" (car case) (cdr case) report)))
  ;; A password must not appear in any refusal, however the base is shaped. The parse-failure
  ;; branch used to print the base and then quri's error text, which quotes the URI again, so a
  ;; password appeared twice (the review of #1084).
  (dolist (base (list "https://AC1:tOpS3cret@api.example.invalid/2010-04-01"
                      "https://AC1:tOpS3cret with spaces@api.example.invalid/x"
                      "https://AC1:tOpS3cret\"@api.example.invalid/x"
                      "https://AC1:tOpS3cret<@api.example.invalid/x"
                      "http://AC1:tOpS3cret@127.0.0.1:4010"))
    (let ((report (%api-base-refusal base)))
      (is-true report "~S is refused" base)
      (is-false (and report (search "tOpS3cret" report))
                "and its report does not contain the password: ~A" report)))
  ;; The controls: every legitimate base is accepted, and the URL a request is built from
  ;; addresses the host that was approved.
  (dolist (case '(("https://api.twilio.invalid/2010-04-01"
                   . "https://api.twilio.invalid/2010-04-01/Accounts/ACx/Messages.json")
                  ("http://localhost:4010" . "http://localhost:4010/Accounts/ACx/Messages.json")
                  ("http://127.0.0.1:4010/2010-04-01"
                   . "http://127.0.0.1:4010/2010-04-01/Accounts/ACx/Messages.json")
                  ("http://10.0.0.5" . "http://10.0.0.5/Accounts/ACx/Messages.json")
                  ("http://192.168.1.9:8080" . "http://192.168.1.9:8080/Accounts/ACx/Messages.json")
                  ("http://169.254.10.10" . "http://169.254.10.10/Accounts/ACx/Messages.json")))
    (let ((p (h:make-twilio :account-sid "ACx" :auth-token "t" :api-base (car case))))
      (is (string= (cdr case) (hermes::%twilio-endpoint (h:twilio-api-base p) "ACx"))
          "~A is accepted and builds ~A" (car case) (cdr case))))
  ;; And the pair that shows the plaintext rule is about the scheme and the host together: the
  ;; same remote host over https is fine, and the same plaintext scheme is fine locally.
  (is-false (%api-base-refusal "https://api.twilio.invalid/2010-04-01")
            "control: https to a remote host that http was refused for")
  (is-false (%api-base-refusal "http://127.0.0.1:1/x")
            "control: http to a local host, the same scheme refused remotely"))

;;; --- SendGrid's endpoint, checked by the same rule as Twilio's API base (#1092) -----------
;;;
;;; These live beside the Twilio ones because they are the same check. The file is named for the
;;; timeouts of #1077, which is where that check arrived; the name has drifted.

(defun %sendgrid-refusal (endpoint)
  "The report of the CONFIGURATION-ERROR refusing ENDPOINT, or NIL if it was accepted."
  (handler-case (progn (h:make-sendgrid :api-key "SG.key" :endpoint endpoint) nil)
    (h:configuration-error (e) (princ-to-string e))))

(test a-sendgrid-endpoint-is-refused-for-the-reason-it-deserves
  "#1092: every SendGrid request carries the API key as a Bearer credential in an Authorization
header, and until this the endpoint was not checked at all, so
(MAKE-SENDGRID :ENDPOINT \"http://evil.example/v3/mail/send\") sent the key in plaintext to
whatever host was named.

Each case asserts WHICH check refused it, not merely that something did: a list of endpoints that
all signal the same condition would pass if one check were doing all the work."
  (dolist (case '(("http://evil.example/v3/mail/send" . "in the clear")
                  ("http://8.8.8.8/v3/mail/send" . "in the clear")
                  ("http://010.0.0.1/v3/mail/send" . "in the clear")
                  ("https://SG:pw@api.example.invalid/x" . "user name or password")
                  ("http://[::1]@host.invalid/x" . "user name or password")
                  ("https://[::1]@127.0.0.1/x" . "user name or password")
                  ("evil.invalid://127.0.0.1" . "The scheme is")
                  ("api.sendgrid.invalid/v3/mail/send" . "The scheme is")
                  ("//host.invalid/x" . "The scheme is")
                  ("http://[::1]:4010/x" . "bracketed IPv6")))
    (let ((report (%sendgrid-refusal (car case))))
      (is-true report "~S is refused" (car case))
      (is-true (and report (search (cdr case) report))
               "~S is refused for ~S: ~A" (car case) (cdr case) report)))
  ;; No refusal may repeat the value, which may hold a password.
  (dolist (endpoint (list "https://SG:tOpS3cret@api.example.invalid/x"
                          "https://SG:tOpS3cret with spaces@api.example.invalid/x"
                          "http://SG:tOpS3cret@127.0.0.1:4010/x"
                          "https://SG:tOpS3cret\"@api.example.invalid/x"))
    (let ((report (%sendgrid-refusal endpoint)))
      (is-true report "~S is refused" endpoint)
      (is-false (and report (search "tOpS3cret" report))
                "and its report does not contain the password: ~A" report)))
  ;; The controls: every legitimate endpoint is accepted and read back unchanged.
  (dolist (endpoint '("https://api.sendgrid.com/v3/mail/send"
                      "https://api.eu.sendgrid.com/v3/mail/send"
                      "http://localhost:4010/v3/mail/send"
                      "http://127.0.0.1:4010/v3/mail/send"
                      "http://10.0.0.5/v3/mail/send"))
    (let ((p (h:make-sendgrid :api-key "SG.key" :endpoint endpoint)))
      (is (string= endpoint (h:sendgrid-endpoint p)) "~A is accepted unchanged" endpoint)))
  ;; A QUERY IS ACCEPTED HERE, unlike in a Twilio API base. DELIVER sends this value as the
  ;; request URL exactly as it stands, so nothing can land inside a query; refusing one would
  ;; turn away a legitimate local mock. That difference is :APPENDS-PATH.
  (is-false (%sendgrid-refusal "http://127.0.0.1:4010/v3/mail/send?trace=1")
            "a query is harmless when nothing is appended to the endpoint")
  (is-true (search "query or a fragment"
                   (or (%api-base-refusal "https://api.twilio.invalid/x?q=1") ""))
           "control: the same shape IS refused for Twilio, where a path is appended")
  ;; And the default is unchanged by any of this.
  (is (string= "https://api.sendgrid.com/v3/mail/send"
               (h:sendgrid-endpoint (h:make-sendgrid :api-key "SG.key")))
      "the default endpoint still makes a provider"))

(test a-configured-url-is-checked-on-reinitialize-too
  "The review of #1104. The check hung off INITIALIZE-INSTANCE :AFTER, which
REINITIALIZE-INSTANCE does not call, so a provider could be made with a good URL and then pointed
somewhere else:

  (reinitialize-instance (make-instance 'hermes::sendgrid :api-key \"k\") :endpoint \"http://evil/x\")

was accepted, and the next send carried the credential there in plaintext. Both backends check on
SHARED-INITIALIZE :AFTER now, which runs for both."
  (let ((p (h:make-sendgrid :api-key "SG.key")))
    (signals h:configuration-error
      (reinitialize-instance p :endpoint "http://evil.invalid/v3/mail/send"))
    ;; The control: a legitimate endpoint still reinitializes, so the refusal is about the value
    ;; and not about REINITIALIZE-INSTANCE having been closed off.
    (reinitialize-instance p :endpoint "http://127.0.0.1:4010/v3/mail/send")
    (is (string= "http://127.0.0.1:4010/v3/mail/send" (h:sendgrid-endpoint p))
        "control: a local endpoint is accepted on reinitialize"))
  (let ((p (h:make-twilio :account-sid "ACx" :auth-token "t")))
    (signals h:configuration-error
      (reinitialize-instance p :api-base "http://evil.invalid/2010-04-01"))
    (reinitialize-instance p :api-base "http://127.0.0.1:4010/2010-04-01")
    (is (string= "http://127.0.0.1:4010/2010-04-01" (h:twilio-api-base p))
        "control: and the same for Twilio")))

(test a-control-character-in-a-configured-url-is-refused
  "The review of #1104 found that \"http://127.0.0.1/x\" with a newline and a Host: line after it
was accepted. The credential would still have gone only to the local host, so this was not an
escape, but a value that cannot appear in a URL has no reading worth arguing about: refusing it
removes the question instead of answering it."
  (dolist (bad (list (format nil "http://127.0.0.1:4010/x~CHost: evil.invalid" #\Newline)
                     (format nil "http://127.0.0.1:4010/x~C" #\Return)
                     (format nil "http://127.0.0.1:4010/~Cx" #\Tab)
                     (format nil "http://127.0.0.1:4010/~Cx" (code-char 0))
                     (format nil "http://127.0.0.1:4010/~Cx" (code-char 127))))
    (dolist (refusal (list (%sendgrid-refusal bad) (%api-base-refusal bad)))
      (is-true refusal "a control character is refused")
      (is-true (and refusal (search "control characters" refusal))
               "and the report says which check refused it: ~A" refusal)))
  ;; The control: the same URL without the control character is accepted by both.
  (is-false (%sendgrid-refusal "http://127.0.0.1:4010/x") "control: the clean URL is accepted")
  (is-false (%api-base-refusal "http://127.0.0.1:4010/x") "by both backends"))

(test the-credential-url-check-is-one-check-for-both-backends
  "#1092's reason for existing. TWO BACKENDS, not every backend: Telegram, Facebook, Stripe and
hermes/blob do not call this yet, which is #1106, and an earlier version of this file's prose
claimed otherwise (the review of #1104).

The locality half of this rule was written twice -- hermes core
for a Twilio API base, hermes/blob for an S3 endpoint -- and the two copies acquired three
different holes between them, each a case the other's fix had already closed (#1089, and the
reviews of #1084 and #1090). SendGrid had no check at all. A third hand-written copy would have
been the same bet, so both backends call %CHECK-CREDENTIAL-URL.

This asserts the sharing rather than trusting it: for each shape, both providers refuse, and for
the same stated reason."
  (dolist (case '(("http://evil.invalid/x" . "in the clear")
                  ("https://u:pw@evil.invalid/x" . "user name or password")
                  ("evil.invalid://127.0.0.1" . "The scheme is")
                  ("http://[::1]:4010/x" . "bracketed IPv6")
                  ("//evil.invalid/x" . "The scheme is")))
    (let ((sendgrid (%sendgrid-refusal (car case)))
          (twilio (%api-base-refusal (car case))))
      (is-true (and sendgrid twilio) "~S is refused by both" (car case))
      (is-true (and sendgrid (search (cdr case) sendgrid))
               "sendgrid refuses ~S for ~S" (car case) (cdr case))
      (is-true (and twilio (search (cdr case) twilio))
               "and twilio refuses it for the same reason" )))
  ;; The naming differs, deliberately: each report names its own setting and credential, so an
  ;; operator is told which variable to fix and what would have travelled.
  (is-true (search "SendGrid ENDPOINT" (or (%sendgrid-refusal "http://evil.invalid/x") ""))
           "the SendGrid report names its own setting")
  (is-true (search "Twilio API-BASE" (or (%api-base-refusal "http://evil.invalid/x") ""))
           "and the Twilio report names its own")
  (is-true (search "the API key" (or (%sendgrid-refusal "http://evil.invalid/x") ""))
           "and each says what would have travelled")
  (is-true (search "account SID and auth token" (or (%api-base-refusal "http://evil.invalid/x") ""))
           "which is not the same credential"))

(test a-plaintext-provider-at-a-local-NAME-sends-with-no-proxy
  "#1091, for the two providers that send a credential to a configured URL. The same defect as
hermes/blob's, and the same fix: PROXY-ARGUMENTS resolves no name, so a plaintext API base or
endpoint at a NAME was approved for plaintext when the provider was made and then still sent the
credential -- the account SID and auth token in an Authorization header, or the API key -- to
whatever HTTPS_PROXY named, in the clear.

Each provider records the verdict its configuration check already reached, and passes it with the
request. The assertion is on WHAT DEXADOR IS GIVEN: a fixture whose proxy is unreachable would
pass for the wrong reason, and a fixture that only read the slot back would not test that the
value reaches the send at all."
  (let ((seen '())
        (original-request (fdefinition 'dex:request))
        (original-resolve (fdefinition 'aion/http-client:resolve-host)))
    (unwind-protect
         (progn
           (setf (fdefinition 'aion/http-client:resolve-host)
                 (lambda (host)
                   (if (string= host "provider.invalid")
                       (funcall original-resolve "127.0.0.1")
                       (funcall original-resolve host))))
           (setf (fdefinition 'dex:request)
                 (lambda (url &rest args)
                   (push (list url (if (member :proxy args) (list :proxy (getf args :proxy)) :none)
                               (getf args :max-redirects))
                         seen)
                   (error "stopped before sending")))
           (let ((twilio (hermes::make-twilio :account-sid "ACtest" :auth-token "t"
                                              :from "+15005550006"
                                              :api-base "http://provider.invalid:4010/2010-04-01")))
             (is (equal "provider.invalid" (hermes::twilio-api-base-approved-local twilio))
                 "twilio recorded the HOST it approved: ~S"
                 (hermes::twilio-api-base-approved-local twilio))
             (ignore-errors (h:deliver twilio (%an-sms))))
           (let ((sendgrid (hermes::make-sendgrid
                            :api-key "SG.test"
                            :endpoint "http://provider.invalid:4010/v3/mail/send")))
             (is (equal "provider.invalid" (hermes::sendgrid-endpoint-approved-local sendgrid))
                 "sendgrid recorded the HOST it approved: ~S"
                 (hermes::sendgrid-endpoint-approved-local sendgrid))
             (ignore-errors (h:deliver sendgrid (%an-email))))
           ;; The controls: the real https endpoints, whose hosts are never resolved by the
           ;; check and must keep whatever proxy is configured.
           (ignore-errors (h:deliver (hermes::make-twilio :account-sid "ACtest" :auth-token "t"
                                                          :from "+15005550006")
                                     (%an-sms)))
           (ignore-errors (h:deliver (hermes::make-sendgrid :api-key "SG.test") (%an-email))))
      (setf (fdefinition 'dex:request) original-request)
      (setf (fdefinition 'aion/http-client:resolve-host) original-resolve))
    (let ((calls (reverse seen)))
      (is (= 4 (length calls)) "all four sends reached dexador: ~S" calls)
      (is (equal '(:proxy nil) (second (first calls)))
          "twilio's plaintext send to the approved name is not proxied: ~S" (first calls))
      (is (eql 0 (third (first calls)))
          "and is given :max-redirects 0, as an approval does and the literal rule does not: ~S"
          (first calls))
      (is (equal '(:proxy nil) (second (second calls)))
          "and neither is sendgrid's: ~S" (second calls))
      ;; SendGrid's redirect cap too. My reply on #1140 said both arguments were asserted for all
      ;; five senders, and this one was missing until the hub's review of that PR found it.
      (is (eql 0 (third (second calls)))
          "and sendgrid's is given :max-redirects 0 as well: ~S" (second calls))
      (is (eq :none (second (third calls)))
          "twilio's https send keeps whatever proxy is configured: ~S" (third calls))
      (is (eq :none (second (fourth calls)))
          "and so does sendgrid's: ~S" (fourth calls)))))

(test a-refused-url-leaves-the-provider-as-it-was
  "#1129, found by Copilot's review of #1126. The check hung off SHARED-INITIALIZE :AFTER, which
runs once the slots have been assigned, so a refused REINITIALIZE-INSTANCE signalled the error
and LEFT THE REFUSED URL IN THE SLOT. Measured at 7ca13e23:

  (let ((p (make-sendgrid :api-key \"SG.x\")))
    (handler-case (reinitialize-instance p :endpoint \"http://evil.example/x\") (error () nil))
    (sendgrid-endpoint p))   =>  \"http://evil.example/x\"

A caller that handled the refusal and carried on then sent the API key there, and nothing checked
it again. #1104 had already moved the check from INITIALIZE-INSTANCE to SHARED-INITIALIZE so that
REINITIALIZE-INSTANCE could not skip it; this is the door next to that one, where the check runs
but the assignment has already happened.

The check is in an :AROUND method now. It reads the slot after CALL-NEXT-METHOD -- so that a
subclass with an :INITFORM of its own is checked too -- and puts the previous URL AND the previous
verdict back before the refusal propagates.

ONE CASE STARTS FROM AN APPROVED LOCAL ENDPOINT, which is the only way to tell restoring from
clearing. Every case used to start at the https default, where the verdict is NIL already, so an
implementation that dropped the verdict on refusal passed: there was nothing to drop (the
re-review of #1134)."
  (dolist (case (list (list (hermes::make-sendgrid :api-key "SG.x")
                            :endpoint #'hermes::sendgrid-endpoint
                            #'hermes::sendgrid-endpoint-approved-local nil)
                      (list (hermes::make-twilio :account-sid "ACx" :auth-token "t"
                                                 :from "+15005550006")
                            :api-base #'hermes::twilio-api-base
                            #'hermes::twilio-api-base-approved-local nil)
                      ;; The same two, but configured at a local plaintext host that the check
                      ;; approved, so both the URL and the verdict have something to lose.
                      (list (hermes::make-sendgrid
                             :api-key "SG.x" :endpoint "http://127.0.0.1:4010/v3/mail/send")
                            :endpoint #'hermes::sendgrid-endpoint
                            #'hermes::sendgrid-endpoint-approved-local "127.0.0.1")
                      (list (hermes::make-twilio :account-sid "ACx" :auth-token "t"
                                                 :from "+15005550006"
                                                 :api-base "http://127.0.0.1:4010/2010-04-01")
                            :api-base #'hermes::twilio-api-base
                            #'hermes::twilio-api-base-approved-local "127.0.0.1")))
    (destructuring-bind (provider key reader verdict expected-verdict) case
      (let ((before (funcall reader provider)))
        (is (equal expected-verdict (funcall verdict provider))
            "the provider starts with the verdict this case needs: ~S"
            (funcall verdict provider))
        (signals h:configuration-error
          (reinitialize-instance provider key "http://evil.example/x"))
        (is (equal before (funcall reader provider))
            "~S keeps its URL after a refusal: ~S" (type-of provider) (funcall reader provider))
        (is (equal expected-verdict (funcall verdict provider))
            "and keeps the verdict that belongs to it: ~S" (funcall verdict provider))
        ;; The control: a URL the check accepts DOES move, so the assertion above is about the
        ;; refusal and not about REINITIALIZE-INSTANCE being unable to change the slot.
        (reinitialize-instance provider key "https://accepted.example/v1")
        (is (equal "https://accepted.example/v1" (funcall reader provider))
            "control: an accepted URL replaces it: ~S" (funcall reader provider))))))

(defclass %sendgrid-with-its-own-default (hermes::sendgrid)
  ((hermes::endpoint :initform "http://public.invalid/v3/mail/send"))
  (:documentation
   "A subclass that gives the endpoint slot an :INITFORM of its own, which is the case the check
used to miss (the re-review of #1134). Its default is a PLAINTEXT PUBLIC host, so a check that
looks at the slot refuses it and a check that looks at the superclass's default constant does
not."))

(test a-subclass-default-url-is-checked-too
  "The re-review of #1134. The :AROUND check used to work out the value that WOULD be in effect:
the initarg if one was supplied, else the slot if it was bound, else the superclass's default
constant. On a fresh instance of a SUBCLASS that gives the slot its own :INITFORM, none of those
is the value the slot ends up with -- there is no initarg, the slot is not yet bound, and the
constant is the superclass's -- so the subclass's URL was never checked and a plaintext public
endpoint was accepted.

The check reads the slot after CALL-NEXT-METHOD now, so the value it judges is the value the
object has."
  (signals h:configuration-error (make-instance '%sendgrid-with-its-own-default :api-key "SG.x"))
  ;; The control, so this is about the subclass's initform and not about the class being
  ;; unbuildable for some other reason: the same subclass with an acceptable endpoint passed as
  ;; an initarg builds.
  (let ((ok (make-instance '%sendgrid-with-its-own-default
                           :api-key "SG.x" :endpoint "https://api.sendgrid.com/v3/mail/send")))
    (is (equal "https://api.sendgrid.com/v3/mail/send" (hermes::sendgrid-endpoint ok))
        "control: an acceptable endpoint passed as an initarg is kept: ~S"
        (hermes::sendgrid-endpoint ok))))

(define-condition %subclass-initarg-error (error) ()
  (:report (lambda (c s) (declare (ignore c)) (format s "the subclass refused its own initarg"))))

(defclass %sendgrid-with-an-after-method (hermes::sendgrid)
  ()
  (:documentation
   "A subclass with its own SHARED-INITIALIZE :AFTER method, which runs INSIDE the superclass's
:AROUND -- after the URL slot has been assigned. Its method signals for :X :BAD, which is how a
failure arriving from inside CALL-NEXT-METHOD is reproduced (the final review of #1134)."))

(defmethod shared-initialize :after ((p %sendgrid-with-an-after-method) slot-names
                                     &rest initargs &key &allow-other-keys)
  (declare (ignore slot-names))
  (when (eq :bad (getf initargs :x))
    (error '%subclass-initarg-error)))

(test a-failure-from-inside-call-next-method-also-restores-the-url
  "The final review of #1134, and a regression of #1129's property that the fix for it
introduced. The restoring HANDLER-BIND wrapped only the %CHECK-* call, not CALL-NEXT-METHOD -- but
a subclass :AFTER method on SHARED-INITIALIZE runs inside CALL-NEXT-METHOD, after the URL slot has
been assigned. A failure there left the new, UNCHECKED URL in the slot, for exactly the callers
#1129 is about: the ones that handle the error and carry on.

Here the subclass refuses :X :BAD, so the error comes from inside CALL-NEXT-METHOD rather than
from the URL check, and the URL being set in the same call is one the check would also have
refused. Either way it must not survive."
  (let ((p (make-instance '%sendgrid-with-an-after-method :api-key "SG.x")))
    (is (equal hermes::+sendgrid-endpoint-default+ (hermes::sendgrid-endpoint p))
        "it starts at the default: ~S" (hermes::sendgrid-endpoint p))
    (signals %subclass-initarg-error
      (reinitialize-instance p :endpoint "http://evil.example/x" :x :bad))
    (is (equal hermes::+sendgrid-endpoint-default+ (hermes::sendgrid-endpoint p))
        "and keeps it when the subclass's own method signals: ~S" (hermes::sendgrid-endpoint p))
    (is-false (hermes::sendgrid-endpoint-approved-local p)
              "with no approval claimed: ~S" (hermes::sendgrid-endpoint-approved-local p))
    ;; The control: the same subclass accepts a good initarg and does move the endpoint, so the
    ;; assertion above is about the failure and not about this subclass being unable to change.
    (reinitialize-instance p :endpoint "https://accepted.example/v1" :x :fine)
    (is (equal "https://accepted.example/v1" (hermes::sendgrid-endpoint p))
        "control: a good initarg lets the endpoint move: ~S" (hermes::sendgrid-endpoint p))))

;;;; #1106: every backend that sends a credential to a configured URL runs the same check.

(defun %provider-refusal (make key value)
  "The refusal text from building a provider with KEY bound to VALUE, or NIL when it was accepted."
  (handler-case (progn (funcall make key value) nil)
    (h:configuration-error (e) (h:configuration-error-missing e))))

(defparameter *url-checked-providers*
  (list (list "Twilio" (lambda (key value) (hermes::make-twilio :account-sid "ACx" :auth-token "t"
                                                                :from "+15005550006" key value))
              :api-base "Twilio API-BASE")
        (list "SendGrid" (lambda (key value) (hermes::make-sendgrid :api-key "SG.x" key value))
              :endpoint "SendGrid ENDPOINT")
        (list "Telegram" (lambda (key value) (hermes::make-telegram :token "t" key value))
              :api-base "Telegram API-BASE")
        (list "Facebook" (lambda (key value) (hermes::make-facebook :app-id "a" :app-secret "s"
                                                                    key value))
              :graph-base "Facebook GRAPH-BASE"))
  "The hermes-core providers that send a credential to a configured URL, and the initarg that
carries it. Stripe is the fifth and is tested in hermes/payments/tests, because it is in another
system; hermes/blob's S3 endpoint is the sixth and is tested in blob.lisp, because it is a bare
authority rather than a URL and signals its own condition.")

(test every-provider-refuses-a-url-it-cannot-send-a-credential-to
  "#1106. Twilio's API base and SendGrid's endpoint were checked; Telegram's api-base, Facebook's
graph-base and Stripe's api-base were not, and hermes/blob kept its own copy of part of the rule.
Four more call sites each deciding for themselves is the bet that produced the first three holes
-- a bracketed IPv6 address in the userinfo, a scheme inside the endpoint, and a bucket label in
front of the host -- each of which was a case another copy's fix had already closed.

EACH CASE ASSERTS WHICH REFUSAL FIRED, not merely that something did. A test that accepts any
refusal cannot tell the rule from a typo in the value: `evil.example://127.0.0.1' must be refused
for its SCHEME, because a check that looked for `http' would read the host as 127.0.0.1 and let
it through, and a test satisfied by any refusal would pass while that hole was open."
  (dolist (provider *url-checked-providers*)
    (destructuring-bind (name make key setting) provider
      (dolist (case (list (cons "http://evil.example/x" "in the clear")
                          (cons "evil.example://127.0.0.1" "The scheme is")
                          (cons "https://u:pw@api.example.com" "user name or password")
                          (cons "https://[::1]/x" "bracketed IPv6 address")
                          ;; QURI PARSES THIS WITHOUT COMPLAINT, so the refusal is the one about
                          ;; the scheme rather than a parse failure. Worth asserting as the reason
                          ;; it actually is: a value that is not a URL at all still reaches the
                          ;; scheme branch, which is the branch that stops
                          ;; `evil.example://127.0.0.1' too.
                          (cons "not a url at all" "The scheme is")
                          (cons (format nil "https://api.example.com/x~Cy" #\Newline)
                                "without control characters")))
        (let ((refusal (%provider-refusal make key (car case))))
          (is-true refusal "~A refuses ~S" name (car case))
          (is-true (and refusal (search (cdr case) refusal))
                   "~A refuses ~S for the right reason, not another: ~A" name (car case) refusal)
          (is-true (and refusal (search setting refusal))
                   "~A names the setting in its refusal: ~A" name refusal)))
      ;; The control: each provider still accepts a URL it may send to, so the refusals above are
      ;; about the values and not about the provider having become unbuildable.
      (is-false (%provider-refusal make key "https://api.example.com/v1")
                "control: ~A accepts an https URL" name)
      (is-false (%provider-refusal make key "http://127.0.0.1:4010/v1")
                "control: ~A accepts a local plaintext URL" name))))

(test no-provider-refusal-repeats-the-configured-value
  "#1106, and the reason the shared rule's refusals are worded as they are: the value may carry a
password -- that is one of the things refused -- and these reports reach logs and terminals. One
copy of this rule printed the value in every branch, and its parse-failure branch appended quri's
error text, which quotes the URI again, so a password appeared twice (the review of #1084). Every
backend now inherits the wording that does not.

THE HOST AND THE SCHEME ARE ECHOED ON PURPOSE, so this test is about the branches where the value
is a secret rather than about every branch. `The host \"evil.example\" would receive ...' and
`The scheme is \"evil.example\"' are the whole use of those refusals: they tell the operator where
the bytes would have gone, which is the fact that makes the refusal actionable. A first version of
this test planted the password in the host and in the scheme and asserted it was not echoed, which
would have been a demand to make those refusals useless.

What must not be echoed is the USERINFO, which is where a password lives, and the whole value in
the two branches that cannot read it: a value quri will not parse, and a value with a control
character in it."
  (dolist (provider *url-checked-providers*)
    (destructuring-bind (name make key setting) provider
      (declare (ignore setting))
      (dolist (value (list "https://user:hunter2@api.example.com"
                           "http://user:hunter2@127.0.0.1:4010"
                           (format nil "https://api.example.com/x~Chunter2" #\Newline)
                           (format nil "https://api.example.com/x~Chunter2" (code-char 127))))
        (let ((refusal (%provider-refusal make key value)))
          (is-true refusal "~A refuses ~S" name value)
          (is-false (and refusal (search "hunter2" refusal))
                    "~A does not repeat the secret in its refusal: ~A" name refusal)))
      ;; The control: the refusal for a userinfo value DOES name the host, which is the fact it
      ;; exists to report, so the assertion above is about the password and not about the refusal
      ;; having been emptied out.
      (let ((refusal (%provider-refusal make key "https://user:hunter2@api.example.com")))
        (is-true (and refusal (search "api.example.com" refusal))
                 "control: ~A still reports the host the request would reach: ~A"
                 name refusal)))))

(test every-provider-rechecks-its-url-on-reinitialize
  "#1106 and #1104. REINITIALIZE-INSTANCE does not call INITIALIZE-INSTANCE, so a check on the
latter is one a caller can walk around:

  (reinitialize-instance <provider> <key> `http://evil.example/x')

was accepted for SendGrid and Twilio until the review of #1104, and the next send carried the
credential there in plaintext. Every provider's check is on SHARED-INITIALIZE, so there is no
second door, and a refusal leaves the previous URL in place (#1129)."
  (dolist (provider *url-checked-providers*)
    (destructuring-bind (name make key setting) provider
      (declare (ignore setting))
      (let* ((p (funcall make key "https://api.example.com/v1"))
             (reader (lambda () (slot-value p (if (eq key :api-base) 'hermes::api-base
                                                  (if (eq key :graph-base) 'hermes::graph-base
                                                      'hermes::endpoint))))))
        (signals h:configuration-error
          (reinitialize-instance p key "http://evil.example/x"))
        (is (equal "https://api.example.com/v1" (funcall reader))
            "~A keeps its URL when a reinitialize is refused: ~S" name (funcall reader))
        ;; The control: an acceptable URL does replace it.
        (reinitialize-instance p key "https://other.example/v2")
        (is (equal "https://other.example/v2" (funcall reader))
            "control: ~A accepts a good URL on reinitialize: ~S" name (funcall reader))))))

(test telegram-and-facebook-bind-their-approval-around-the-send
  "The review of #1140, and a gap of exactly the shape AGENTS.md warns about: the slot was
recorded, the binder was called at the send site, and NOTHING TESTED THE CALL. Removing
CALL-WITH-APPROVED-LOCAL-HOST from telegram.lisp or facebook.lisp passed every suite, because the
recorded verdict was asserted in one test and the proxy argument in another, and no test joined
them for these providers. Twilio and SendGrid have had that test since #1091; these did not, and
Stripe's equivalent is in hermes/payments/tests because it is in another system.

THE ASSERTION IS ON WHAT DEXADOR RECEIVES, which is the only place the two halves meet. It cannot
be done through the *TELEGRAM-PERFORM* and *FACEBOOK-PERFORM* pivots: those replace the whole
performing function, so %DEX-ARGS and PROXY-ARGUMENTS never run and the argument under test is
never computed. This stubs DEX:REQUEST instead and leaves the pivots alone.

Both directions for each: a plaintext base at a host the check approved as local is sent with
:PROXY NIL, and the same provider at its https default is not."
  (let ((seen '())
        (original-request (fdefinition 'dex:request))
        (original-resolve (fdefinition 'aion/http-client:resolve-host)))
    (unwind-protect
         (progn
           (setf (fdefinition 'aion/http-client:resolve-host)
                 (lambda (host)
                   (if (string= host "provider.invalid")
                       (funcall original-resolve "127.0.0.1")
                       (funcall original-resolve host))))
           (setf (fdefinition 'dex:request)
                 (lambda (url &rest args)
                   (push (list url (if (member :proxy args) :no-proxy :proxied)
                               ;; AND THE REDIRECT CAP: an approval answers
                               ;; (:PROXY NIL :MAX-REDIRECTS 0) while the literal
                               ;; rule answers (:PROXY NIL) alone, so recording only
                               ;; :PROXY cannot tell which rule granted the exemption
                               ;; (the review of #1140).
                               (getf args :max-redirects))
                         seen)
                   (error "stopped before sending")))
           ;; Telegram: the token is in the path, so this is the one where a proxy would log it.
           (dolist (base '("http://provider.invalid:8081" "https://api.telegram.org"))
             (ignore-errors
              (h:deliver (hermes::make-telegram :token "t" :api-base base)
                         ;; A VALID CHAT ID. "@c" is refused by Telegram's own message check --
                         ;; it wants "@" and 5 to 32 characters -- so the send never reached
                         ;; dexador and the first version of this test measured two facebook
                         ;; calls while claiming four.
                         (h:make-telegram-message :chat "@news_channel" :text "x"))))
           ;; Facebook: a POST, which carries the access token in the form body.
           (dolist (base '("http://provider.invalid:8081" "https://graph.facebook.com"))
             (ignore-errors
              (h:deliver (hermes::make-facebook :app-id "111" :app-secret "s"
                                                :page-tokens (list (cons "1234567890" "tok"))
                                                :graph-base base)
                         (h:make-facebook-post :page "1234567890" :message "hi")))))
      (setf (fdefinition 'dex:request) original-request)
      (setf (fdefinition 'aion/http-client:resolve-host) original-resolve))
    (let ((calls (reverse seen)))
      (is (= 4 (length calls)) "all four sends reached dexador: ~S" calls)
      (dolist (pair '((0 . "telegram") (2 . "facebook")))
        (let ((local (nth (car pair) calls))
              (remote (nth (1+ (car pair)) calls)))
          (is (eq :no-proxy (second local))
              "~A's plaintext send to the approved host is not proxied: ~S" (cdr pair) local)
          (is (eql 0 (third local))
              "~A's approved send is also given :max-redirects 0: ~S" (cdr pair) local)
          (is (eq :proxied (second remote))
              "~A's https send keeps whatever proxy is configured: ~S" (cdr pair) remote))))))

(test a-refused-url-leaves-every-other-slot-as-it-was
  "The hub's review of #1140. The restore put back the URL and the recorded verdict by name, and
CALL-NEXT-METHOD assigns every initarg in the call before the URL check runs. So a refused

  (reinitialize-instance provider :read-timeout 99 :endpoint `http://evil.example/x')

kept the new read timeout while putting the URL back, and the CHANGELOG said a refusal left the
provider \"exactly as it was\". For these providers that leaked nothing -- the scheme lives in the
URL slot, which was restored -- but hermes/blob's copy of the same ordering missed SECURE in the
same way and was left plaintext with no approval. Every slot is snapshotted now, so the claim is
true rather than true of the two slots someone remembered."
  (dolist (case (list (list (hermes::make-sendgrid :api-key "SG.x" :read-timeout 5)
                            :endpoint #'hermes::sendgrid-read-timeout)
                      (list (hermes::make-twilio :account-sid "ACx" :auth-token "t"
                                                 :from "+15005550006" :read-timeout 5)
                            :api-base #'hermes::twilio-read-timeout)))
    (destructuring-bind (provider key read-timeout) case
      (signals h:configuration-error
        (reinitialize-instance provider :read-timeout 99 key "http://evil.example/x"))
      (is (eql 5 (funcall read-timeout provider))
          "~S keeps its read timeout when the same call's URL is refused: ~S"
          (type-of provider) (funcall read-timeout provider))
      ;; The control: with an acceptable URL the same call does change the timeout, so the
      ;; assertion above is about the refusal and not about the slot being unchangeable.
      (reinitialize-instance provider :read-timeout 99 key "https://accepted.example/v1")
      (is (eql 99 (funcall read-timeout provider))
          "control: an accepted call changes it: ~S" (funcall read-timeout provider)))))
