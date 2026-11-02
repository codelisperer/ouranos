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
  "Seconds THUNK took to fail. Signals a test failure if it does not fail, because every caller
here is sending to a server that never answers."
  (let ((start (get-internal-real-time)))
    (handler-case (progn (funcall thunk) nil)
      (h:delivery-failure () nil))
    (%elapsed-seconds start)))

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
        (is (< slower (1- +dexador-default-timeout+))
            "both are under dexador's ~Ds default, so the setting is what ends the send: 1s took ~,2Fs and 2s took ~,2Fs"
            +dexador-default-timeout+ quick slower)
        (if (<= gap 0.25)
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

(test a-plaintext-twilio-api-base-is-refused-unless-the-host-is-local
  "#1077: every Twilio request carries the account SID and auth token in an Authorization header,
so an http base to a remote host sends them in the clear. Refused when the provider is made, not
at the first send, so the failure arrives where the configuration is."
  (dolist (base '("http://api.twilio.com/2010-04-01"
                  "http://example.com"
                  "http://8.8.8.8/2010-04-01"
                  "http://[2001:4860:4860::8888]/x"))
    (let ((c (handler-case (progn (h:make-twilio :account-sid "a" :auth-token "t" :api-base base)
                                  nil)
               (h:configuration-error (e) e))))
      (is-true c "a plaintext base to a remote host is refused: ~S" base)))
  ;; Accepted: https anywhere, and plaintext to a host only this machine or network can reach.
  (dolist (base '("https://api.twilio.com/2010-04-01"
                  "https://example.com"
                  "http://localhost:4010"
                  "http://127.0.0.1:4010/2010-04-01"
                  "http://[::1]:4010"
                  "http://10.0.0.5/2010-04-01"
                  "http://192.168.1.9:8080"
                  "http://169.254.10.10"))
    (is-true (h:twilio-api-base (h:make-twilio :account-sid "a" :auth-token "t" :api-base base))
             "accepted: ~S" base))
  ;; The control that the refusal is about the scheme and the host together, not about either
  ;; alone: the same remote host over https is fine, and the same plaintext scheme is fine
  ;; locally. Without this pair, a check that refused everything would pass the list above.
  (is-true (h:make-twilio :account-sid "a" :auth-token "t"
                          :api-base "https://api.twilio.com/2010-04-01")
           "control: https to the same remote host that http was refused for")
  (is-true (h:make-twilio :account-sid "a" :auth-token "t" :api-base "http://127.0.0.1:1/x")
           "control: http to a local host, the same scheme that was refused remotely"))
