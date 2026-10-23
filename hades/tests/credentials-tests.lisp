;;;; credentials-tests.lisp --- the credential store round-trips, and the value never shows (#357).
;;;;
;;;; Every item uses a service name unique to the run and is deleted afterwards. The value is a
;;;; marker unique to the run, so a search of any text for it can only find a leak.
;;;;
;;;; THE LIVE TESTS USE THE REAL STORE. They store, read and delete items in the Credential
;;;; Manager, login Keychain or Secret Service keyring of whoever runs them, so they run only when
;;;; OURANOS_TEST_REAL_CREDENTIAL_STORE=1 is set. CI sets it, because a runner's store is thrown
;;;; away with the runner. On a developer's machine the maintainer decides whether to set it.
;;;; RUN-TESTS reports which happened as a BACKEND-CHECKS credential-store line, and
;;;; scripts/verify-tree.lisp fails a skipped run unless OURANOS_ALLOW_NO_CREDENTIAL_STORE=1
;;;; excuses it, as it does for Postgres.
;;;;
;;;; What a live run touches: only items whose service starts with
;;;; "ouranos-test-hades-credentials/", each with a random suffix, so it cannot meet an item it
;;;; did not create. Each test deletes its item when it ends, however it ends. A delete that fails
;;;; is printed, naming the item and never its value, and recorded; the LEFTOVERS suite then
;;;; fails on it, and also checks that every item the run created can no longer be fetched. It
;;;; does not list the store, which would read the names of every credential the user has.

(defpackage #:hades/credentials/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cred #:hades/credentials) (#:sec #:aion/secret))
  #+linux (:local-nicknames (#:libsecret #:aion/libsecret) (#:ffi #:aion/libsecret/ffi))
  (:export #:run-tests))

(in-package #:hades/credentials/tests)

(def-suite all :description "hades/credentials: the tests that store, change and delete nothing.")
(def-suite live :description "hades/credentials: the tests that use this machine's real store.")
(def-suite leftovers :description "hades/credentials: nothing the live tests created remains.")

(defparameter +live-variable+ "OURANOS_TEST_REAL_CREDENTIAL_STORE"
  "The environment variable that lets the live tests use this machine's real store.")

(defun %live-p ()
  (let ((v (uiop:getenv +live-variable+)))
    (and v (member (string-trim " " v) '("1" "true" "yes") :test #'string-equal) t)))

(defvar *created* '()
  "(service . account) for every item a live test has stored, or tried to, in this run.")

(defvar *undeleted* '()
  "(service . account) for every item whose cleanup delete signalled an error in this run.")

(defun run-tests ()
  "Run the tests that touch no store, then, on Windows, macOS and Linux, the live tests if
+LIVE-VARIABLE+ allows them, and print a BACKEND-CHECKS credential-store line saying which.

Signals an error when any of those suites had a failure, after all of them have run, so the
child exits non-zero (Copilot's review of #603). This prints up to three FiveAM reports. Since
#605 the gate passes a suite only when every report in its output says \"Fail: 0\", so a failed
report is caught there too; the non-zero exit makes the failure visible to anything else that
runs this system, such as ASDF:TEST-SYSTEM in a shell."
  (let ((passed (fiveam:run! 'all)))
    #+(or win32 darwin linux)
    (if (%live-p)
        (let ((results (fiveam:run 'live)))
          (fiveam:explain! results)
          (format t "~&BACKEND-CHECKS credential-store ~D~%" (length results))
          (unless (fiveam:results-status results) (setf passed nil))
          ;; Run even when a live test failed: that is when an item is most likely left behind.
          (unless (fiveam:run! 'leftovers) (setf passed nil)))
        (format t "~&BACKEND-CHECKS credential-store SKIPPED (~A is not set; the live tests use this machine's real credential store)~%"
                +live-variable+))
    (unless passed
      (error "hades/credentials/tests: a check failed; the reports above say which"))
    passed))

(defun %token ()
  (format nil "~36R" (random (expt 36 12) (make-random-state t))))

(defun %service ()
  "A service name unique to the run, recorded in *CREATED* with ACCOUNT by %ITEM."
  (concatenate 'string "ouranos-test-hades-credentials/" (%token)))

(defun %item (service account)
  "Record SERVICE and ACCOUNT as an item this run is about to store, and return SERVICE."
  (push (cons service account) *created*)
  service)

(defun %cleanup (service account)
  "Delete the item SERVICE / ACCOUNT at the end of a test. NIL from DELETE-CREDENTIAL means the
test had already deleted it. An error is printed, naming the item and not its value, and
recorded in *UNDELETED*, rather than ignored."
  (handler-case (cred:delete-credential service account)
    (cred:credential-error (e)
      (push (cons service account) *undeleted*)
      (format *error-output* "~&hades/credentials/tests: could not delete the test item ~S / ~S: ~A~%"
              service account e))))

(defun %marker ()
  "A value to store: unique to the run, with a non-ASCII character, and never printed."
  (concatenate 'string "sk-test-" (%token) (string (code-char #xE9)) (%token)))

(defmacro %capturing ((text) &body body)
  "Run BODY with standard and error output collected, then bind TEXT to what was written."
  (let ((out (gensym "OUT")))
    `(let* ((,out (make-string-output-stream))
            (*standard-output* ,out)
            (*error-output* ,out)
            (*trace-output* ,out))
       (let ((,text (progn ,@body (get-output-stream-string ,out))))
         ,text))))

;;; --- live: this machine's real store -------------------------------------------------------

#+(or win32 darwin linux)
(progn
  (in-suite live)

  (test a-value-with-a-nul-character-round-trips-whole
    "The value is stored as bytes with a length on every backend, so it is not cut at a NUL. On
Linux this is why the backend uses libsecret's _binary_ calls rather than the text ones."
    (let* ((service (%item (%service) "user"))
           (value (concatenate 'string (%marker) (string (code-char 0)) (%marker))))
      (unwind-protect
           (progn
             (cred:store-credential service "user" (sec:make-secret value))
             (is (string= value (sec:reveal (cred:fetch-credential service "user")))))
        (%cleanup service "user"))))

  (test a-credential-round-trips-and-is-deleted
    (let ((service (%item (%service) "user")) (value (%marker)) (second (%marker)))
      (unwind-protect
           (progn
             (is (eq t (cred:store-credential service "user" (sec:make-secret value))))
             (let ((got (cred:fetch-credential service "user")))
               (is (sec:secretp got) "fetch must return an aion/secret")
               (is (string= value (sec:reveal got))))
             (cred:store-credential service "user" (sec:make-secret second))
             (is (string= second (sec:reveal (cred:fetch-credential service "user")))
                 "storing again must replace the value")
             (is (eq t (cred:delete-credential service "user")))
             (is (null (cred:delete-credential service "user")) "deleting what is gone returns NIL")
             (signals cred:credential-not-found (cred:fetch-credential service "user")))
        (%cleanup service "user"))))

  (test names-with-non-ascii-characters-round-trip
    (let* ((account (concatenate 'string "b" (string (code-char #xF6)) "b"))
           (service (%item (concatenate 'string (%service) (string (code-char #x6587))) account))
           (value (%marker)))
      (unwind-protect
           (progn
             (cred:store-credential service account (sec:make-secret value))
             (is (string= value (sec:reveal (cred:fetch-credential service account)))))
        (%cleanup service account))))

  (test the-value-never-appears-in-output-or-a-condition
    (let* ((service (%item (%service) "user")) (value (%marker))
           (huge (concatenate 'string value (make-string 3000 :initial-element #\x)))
           (reports '()))
      (unwind-protect
           (let ((text
                   (%capturing (text)
                     (cred:store-credential service "user" (sec:make-secret value))
                     (let ((got (cred:fetch-credential service "user")))
                       (format t "~A ~S~%" got got)
                       (describe got))
                     (handler-case (cred:store-credential service "user" (sec:make-secret huge))
                       (cred:credential-too-large (e) (push (princ-to-string e) reports)))
                     (handler-case (cred:store-credential service "user" value)
                       (type-error (e) (push (princ-to-string e) reports)))
                     (cred:delete-credential service "user")
                     (handler-case (cred:fetch-credential service "user")
                       (cred:credential-not-found (e) (push (princ-to-string e) reports))))))
             (is (= 3 (length reports)) "each refusal must have been signalled: ~S" reports)
             (is (not (search value text)) "the value appeared in printed output")
             (dolist (r reports)
               (is (not (search value r)) "the value appeared in a condition report"))
             ;; The control: the same search does find the value where it is printed on purpose.
             (is (search value (format nil "~A" (sec:reveal (sec:make-secret value))))))
        (%cleanup service "user"))))

  #+linux
  (test an-item-another-program-stored-with-the-same-names-is-not-touched
    "Lookups and deletes match the schema org.codelisperer.hades.Credential as well as the two
attributes, so an item another program stored under its own schema with the same service and
account is neither returned nor deleted."
    (let ((service (%item (%service) "user")) (value (%marker)))
      (flet ((other (fn)
               (libsecret:with-libsecret-lock ()
                 (libsecret:with-schema (schema "org.codelisperer.hades.tests.OtherProgram"
                                                '("service" "account"))
                   (libsecret:with-attributes (attributes (list (cons "service" service)
                                                                (cons "account" "user")))
                     (libsecret:with-gerror (err "the other program's call")
                       (funcall fn schema attributes err)))))))
        (unwind-protect
             (progn
               (let ((v (libsecret:make-secret-value
                         (sb-ext:string-to-octets value :external-format :utf-8))))
                 (unwind-protect
                      (other (lambda (schema attributes err)
                               (ffi:secret-password-storev-binary-sync
                                schema attributes "default" "hades test: another program's item"
                                v (cffi:null-pointer) err)))
                   (ffi:secret-value-unref v)))
               (signals cred:credential-not-found (cred:fetch-credential service "user"))
               (is (null (cred:delete-credential service "user")))
               (let ((found (other (lambda (schema attributes err)
                                     (ffi:secret-password-lookupv-binary-sync
                                      schema attributes (cffi:null-pointer) err)))))
                 (is (not (cffi:null-pointer-p found)) "the other program's item must remain")
                 (unless (cffi:null-pointer-p found) (ffi:secret-value-unref found))))
          (other (lambda (schema attributes err)
                   (ffi:secret-password-clearv-sync schema attributes (cffi:null-pointer) err)))))))

  #+linux
  (test a-stored-value-that-is-not-utf-8-is-refused-without-its-bytes
    "Another program can store any bytes under this schema. Fetching bytes that are not UTF-8
signals CREDENTIAL-ERROR, whose report and slots hold none of them; SBCL's own decoding error
would have carried them."
    (let ((service (%item (%service) "user"))
          (octets (coerce #(115 107 255 254 45 120 121 122) '(vector (unsigned-byte 8)))))
      (unwind-protect
           (progn
             (libsecret:with-libsecret-lock ()
               (libsecret:with-schema (schema hades/credentials::*schema-name*
                                              '("service" "account"))
                 (libsecret:with-attributes (attributes (list (cons "service" service)
                                                              (cons "account" "user")))
                   (let ((v (libsecret:make-secret-value octets)))
                     (unwind-protect
                          (libsecret:with-gerror (err "storing bytes that are not UTF-8")
                            (ffi:secret-password-storev-binary-sync
                             schema attributes "default" "hades test: bytes that are not UTF-8"
                             v (cffi:null-pointer) err))
                       (ffi:secret-value-unref v))))))
             (let ((condition (handler-case (progn (cred:fetch-credential service "user") nil)
                                (error (e) e))))
               (is (typep condition 'cred:credential-error) "got ~S" condition)
               (is (not (typep condition 'cred:credential-not-found)))
               (when condition
                 (let ((report (princ-to-string condition)))
                   (is (search "not UTF-8" report) "~A" report)
                   (is (not (search "xyz" report)) "the bytes appeared in the report: ~A"
                       report)))))
        (%cleanup service "user"))))

  #+linux
  (test a-locked-keyring-is-reported-as-locked-by-every-operation
    "In a new keyring that holds the item, with the default collection then locked, store, fetch
and delete each signal CREDENTIAL-STORE-UNAVAILABLE. Without a display the request to unlock is
never made. With a display on which no prompt can be shown, libsecret asks, gets no answer, and
returns nothing without an error, and that must not read as an absent item. Each case runs in a
child under its own scripts/with-secret-service.sh, so this machine's keyring is never locked."
    (let ((daemon (ignore-errors (uiop:run-program '("sh" "-c" "command -v gnome-keyring-daemon")
                                                   :output '(:string :stripped t)))))
      (if (or (null daemon) (string= "" daemon))
          (skip "gnome-keyring-daemon is not installed, so a keyring cannot be locked here")
          (dolist (case '((("DISPLAY=" "WAYLAND_DISPLAY=") "there is no display")
                          (("DISPLAY=:99" "WAYLAND_DISPLAY=") "the keyring is locked")))
            (destructuring-bind (environment expected) case
              (let ((value (%marker)))
                (multiple-value-bind (text lines)
                    (%child-results
                     environment
                     '(progn
                       (cred:store-credential "ouranos-test-hades-credentials/child" "user"
                                              (sec:make-secret "stored before the lock"))
                       (let ((cl-user::service
                               (libsecret:with-gerror (cl-user::err "reaching the service")
                                 (ffi:secret-service-get-sync ffi:+secret-service-none+
                                                              (cffi:null-pointer) cl-user::err))))
                         (cffi:with-foreign-object (cl-user::paths :pointer 2)
                           (setf (cffi:mem-aref cl-user::paths :pointer 0)
                                 (cffi:foreign-string-alloc
                                  "/org/freedesktop/secrets/aliases/default")
                                 (cffi:mem-aref cl-user::paths :pointer 1) (cffi:null-pointer))
                           (libsecret:with-gerror (cl-user::err "locking the default collection")
                             (ffi:secret-service-lock-dbus-paths-sync
                              cl-user::service cl-user::paths (cffi:null-pointer)
                              (cffi:null-pointer) cl-user::err))))
                       (format t "~&LOCKED ~A~%" (libsecret:default-collection-locked-p)))
                     value :wrapper (%with-secret-service-script))
                  (is (search "LOCKED T" text) "the collection must be locked first:~%~A" text)
                  (is (= 4 (length lines))
                      "the child must report availability and three operations:~%~A" text)
                  ;; Availability does not look at the lock, so it is true here.
                  (is (uiop:string-prefix-p "AVAILABLE T " (first lines)) "~A" (first lines))
                  (dolist (line (rest lines))
                    (is (search "UNAVAILABLE" line) "~A: expected UNAVAILABLE: ~A" environment line)
                    (is (search expected line) "~A: the reason must say ~S: ~A"
                        environment expected line))
                  (is (not (search value text)) "the value appeared in the child's output"))))))))

  #+linux
  (test with-a-secret-service-the-store-is-available-and-asking-creates-nothing
    (multiple-value-bind (available reason) (cred:credential-store-available-p)
      (is (eq t available) "the live tests need a Secret Service: ~A" reason)
      (is (null reason)))
    (is (equal "Secret Service" (cred:credential-store-name)))
    (signals cred:credential-not-found
      (cred:fetch-credential hades/credentials::*probe-service* hades/credentials::*probe-account*)))

  (in-suite leftovers)

  (test every-item-the-live-tests-created-is-gone
    "Each item the live tests stored can no longer be fetched, and no cleanup delete failed. It
fetches by name only the items this run created."
    (is (null *undeleted*) "cleanup could not delete: ~S" *undeleted*)
    (is (plusp (length *created*)) "the live tests recorded no items, so this checked nothing")
    (dolist (item *created*)
      (signals cred:credential-not-found (cred:fetch-credential (car item) (cdr item))))))

;;; --- every platform: nothing here stores, changes or deletes an item ------------------------
;;;
;;; On Windows and macOS the two availability tests (#824) read the store, but only the
;;; probe's own item, which never exists (HADES/CREDENTIALS::*PROBE-SERVICE* and
;;; *PROBE-ACCOUNT*). That is the read an app makes when it asks whether there is a store, so
;;; they run without OURANOS_TEST_REAL_CREDENTIAL_STORE.

(in-suite all)

#-(or win32 darwin linux)
(test with-no-backend-every-call-signals-and-nothing-is-stored
  ;; No file fallback: the store refuses, and a fetch afterwards does not find anything either.
  (let ((service (%service)))
    (signals cred:credential-store-unavailable
      (cred:store-credential service "user" (sec:make-secret (%marker))))
    (signals cred:credential-store-unavailable (cred:fetch-credential service "user"))
    (signals cred:credential-store-unavailable (cred:delete-credential service "user"))))

;;; --- Linux: each reason the Secret Service cannot be used ----------------------------------
;;;
;;; GIO keeps the first session-bus connection a process makes, and libsecret the first service,
;;; so each case runs in a fresh SBCL with its own environment. The child loads this tree's
;;; hades/credentials, tries each operation, and prints one line per operation.

#+linux
(progn
  (defun %tree ()
    (uiop:native-namestring
     (uiop:pathname-parent-directory-pathname
      (asdf:system-source-directory "hades/credentials"))))

  (defun %fresh-directory ()
    (ensure-directories-exist
     (merge-pathnames (format nil "hades-cred-~A/" (%token)) (uiop:temporary-directory))))

  (defparameter *child-deadline* 180
    "Seconds a child SBCL may run before it is killed and the test fails.")

  (defun %child-results (environment prelude value &key wrapper)
    "Run a child SBCL with ENVIRONMENT, a list of \"NAME=VALUE\" strings replacing those
variables, evaluate the form PRELUDE, print what CREDENTIAL-STORE-AVAILABLE-P answers, then
store VALUE and fetch and delete it. Returns the child's whole output as a string, and its lines
that start AVAILABLE, STORE, FETCH or DELETE, in that order. WRAPPER, when given, is a program
the child is run through, such as scripts/with-secret-service.sh. A child still running after
*CHILD-DEADLINE* seconds is killed, and its output then ends with a line saying so."
    (let* ((names (mapcar (lambda (e) (subseq e 0 (1+ (position #\= e)))) environment))
           (env (append environment
                        (remove-if (lambda (e) (some (lambda (n) (uiop:string-prefix-p n e)) names))
                                   (sb-ext:posix-environ))))
           (setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
           (form
             ;; Printed from the keyword package, so every symbol is written with its package,
             ;; and the child, which has no test package, reads the same form back.
             (let ((*package* (find-package :keyword)))
               (prin1-to-string
                `(progn
                   ,prelude
                   (multiple-value-bind (cl-user::available cl-user::why)
                       (cred:credential-store-available-p)
                     (format t "~&AVAILABLE ~A ~A~%" cl-user::available cl-user::why))
                   (dolist (cl-user::op (list (cons "STORE"
                                           (lambda ()
                                             (cred:store-credential
                                              "ouranos-test-hades-credentials/child" "user"
                                              (sec:make-secret ,value))))
                                     (cons "FETCH"
                                           (lambda ()
                                             (cred:fetch-credential
                                              "ouranos-test-hades-credentials/child" "user")))
                                     (cons "DELETE"
                                           (lambda ()
                                             (cred:delete-credential
                                              "ouranos-test-hades-credentials/child" "user")))))
                     (format t "~&~A ~A~%" (car cl-user::op)
                             (handler-case (progn (funcall (cdr cl-user::op)) "RETURNED")
                               (cred:credential-store-unavailable (cl-user::e)
                                 (format nil "UNAVAILABLE ~A"
                                         (cred:credential-store-unavailable-reason cl-user::e)))
                               (error (cl-user::e) (format nil "OTHER ~A" cl-user::e)))))))))
           (sbcl-arguments
             (list "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                   "--eval" "(require :asdf)"
                   "--eval" (format nil "(load ~S)" (uiop:native-namestring setup))
                   "--eval" (format nil "(asdf:initialize-source-registry '(:source-registry (:tree ~S) :inherit-configuration))" (%tree))
                   "--eval" "(let ((*standard-output* (make-broadcast-stream)) (*error-output* (make-broadcast-stream))) (asdf:load-system \"hades/credentials\"))"
                   "--eval" form))
           (process (if wrapper
                        (sb-ext:run-program wrapper
                                            (cons (uiop:native-namestring sb-ext:*runtime-pathname*)
                                                  sbcl-arguments)
                                            :environment env :output :stream :error :output
                                            :wait nil)
                        (sb-ext:run-program sb-ext:*runtime-pathname* sbcl-arguments
                                            :environment env :output :stream :error :output
                                            :wait nil)))
           (killed nil)
           (watchdog (sb-thread:make-thread
                      (lambda ()
                        (loop repeat (* 10 *child-deadline*)
                              while (sb-ext:process-alive-p process)
                              do (sleep 1/10))
                        (when (sb-ext:process-alive-p process)
                          (setf killed t)
                          (sb-ext:process-kill process 9)))
                      :name "hades/credentials/tests child deadline"))
           (text (with-output-to-string (out)
                   (loop for line = (read-line (sb-ext:process-output process) nil)
                         while line do (write-line line out))
                   (sb-ext:process-wait process)
                   (sb-thread:join-thread watchdog)
                   (when killed
                     (format out "KILLED after ~D seconds~%" *child-deadline*)))))
      (sb-ext:process-close process)
      (values text
              (remove-if-not (lambda (line)
                               (some (lambda (op) (uiop:string-prefix-p op line))
                                     '("AVAILABLE " "STORE " "FETCH " "DELETE ")))
                             (uiop:split-string text :separator '(#\Newline))))))

  (defun %check-unavailable (environment prelude expected)
    "CREDENTIAL-STORE-AVAILABLE-P in the child is false with a reason that contains EXPECTED, every
operation signals CREDENTIAL-STORE-UNAVAILABLE with such a reason, and the value never appears in
the child's output."
    (let ((value (%marker)))
      (multiple-value-bind (text lines) (%child-results environment prelude value)
        (is (= 4 (length lines)) "the child must report availability and three operations:~%~A"
            text)
        (is (uiop:string-prefix-p "AVAILABLE NIL " (first lines))
            "available-p must be false: ~A" (first lines))
        (is (search expected (first lines)) "its reason must say ~S: ~A" expected (first lines))
        (dolist (line (rest lines))
          (is (search "UNAVAILABLE" line) "expected UNAVAILABLE: ~A" line)
          (is (search expected line) "the reason must say ~S: ~A" expected line))
        (is (not (search value text)) "the value appeared in the child's output"))))

  (test without-libsecret-every-call-says-it-is-not-installed
    ;; The library is renamed to one no system has, before anything loads it.
    (%check-unavailable
     '() '(cffi:define-foreign-library aion/libsecret/ffi:libsecret
           (:linux "libsecret-not-installed-hades-test.so.0"))
     "libsecret is not installed"))

  (test without-a-session-bus-every-call-says-so
    ;; A socket path in a directory that does not exist, so nothing can be listening there.
    (%check-unavailable
     (list (format nil "DBUS_SESSION_BUS_ADDRESS=unix:path=~Ahades-cred-~A/no-bus-here"
                   (uiop:native-namestring (uiop:temporary-directory)) (%token)))
     nil "there is no D-Bus session bus"))

  (defun %with-secret-service-script ()
    (uiop:native-namestring
     (merge-pathnames "scripts/with-secret-service.sh" (uiop:ensure-directory-pathname (%tree)))))

  (test on-a-bus-with-no-secret-service-every-call-says-so
    "A private session bus whose configuration names no service directories, so nothing can be
started on it to provide org.freedesktop.secrets."
    (let ((daemon (ignore-errors (uiop:native-namestring
                                  (uiop:run-program '("sh" "-c" "command -v dbus-daemon")
                                                    :output '(:string :stripped t))))))
      (if (or (null daemon) (string= "" daemon))
          (skip "dbus-daemon is not installed, so a private bus cannot be started")
          (let* ((dir (%fresh-directory))
                 (config (merge-pathnames "bus.conf" dir))
                 (socket (uiop:native-namestring (merge-pathnames "bus" dir))))
            (with-open-file (out config :direction :output)
              (format out "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">~%<busconfig><type>session</type><listen>unix:path=~A</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow send_destination=\"*\" eavesdrop=\"true\"/><allow eavesdrop=\"true\"/><allow own=\"*\"/></policy></busconfig>~%"
                      socket))
            (let ((bus (sb-ext:run-program daemon
                                           (list "--nofork" "--print-address"
                                                 (format nil "--config-file=~A"
                                                         (uiop:native-namestring config)))
                                           :output :stream :error nil :wait nil)))
              (unwind-protect
                   (let ((address (read-line (sb-ext:process-output bus) nil "")))
                     (is (search "unix:path=" address) "the private bus did not start: ~S" address)
                     (%check-unavailable (list (concatenate 'string "DBUS_SESSION_BUS_ADDRESS="
                                                            address))
                                         nil "no program provides the Secret Service"))
                (sb-ext:process-kill bus 15)
                (sb-ext:process-wait bus)
                (sb-ext:process-close bus)
                (uiop:delete-directory-tree dir :validate t))))))))

(test empty-names-are-refused
  ;; Refused before any store is reached, so this runs without the live variable.
  (signals error (cred:fetch-credential "" "user"))
  (signals error (cred:fetch-credential "service" "")))

;;; --- is there a store? (#824) ----------------------------------------------------------

(test the-store-is-named-and-its-availability-agrees-with-the-operations
  "Where there is a backend the store is available and named; where there is none it is not,
with a reason, and an operation signals CREDENTIAL-STORE-UNAVAILABLE, so the two never disagree."
  (multiple-value-bind (available reason) (cred:credential-store-available-p)
    #+win32 (progn (is (eq t available) "Credential Manager answers on this machine: ~A" reason)
                   (is (equal "Windows Credential Manager" (cred:credential-store-name))))
    #+darwin (progn (is (eq t available))
                    (is (equal "macOS Keychain" (cred:credential-store-name))))
    ;; Either answer is right on Linux, depending on whether a Secret Service is running. When
    ;; it is, the store is not read here: that is the live suite's job, behind the opt-in.
    #+linux
    (progn (is (equal "Secret Service" (cred:credential-store-name)))
           (if available
               (is (null reason))
               (let ((condition (handler-case (cred:fetch-credential (%service) "user")
                                  (cred:credential-store-unavailable (e) e))))
                 (is (stringp reason))
                 (is (typep condition 'cred:credential-store-unavailable))
                 (when (typep condition 'cred:credential-store-unavailable)
                   (is (equal reason (cred:credential-store-unavailable-reason condition))
                       "the operation must give the reason available-p gave")))))
    #-(or win32 darwin linux)
    (progn (is (null available))
           (is (stringp reason))
           (is (null (cred:credential-store-name)))
           (signals cred:credential-store-unavailable
             (cred:fetch-credential (%service) "user")))))

(test asking-whether-the-store-is-available-creates-nothing
  "The probe only reads. Asked twice, the item it reads still does not exist afterwards; where
there is no backend, the fetch says the store is unavailable instead."
  (cred:credential-store-available-p)
  (cred:credential-store-available-p :service "ouranos-test-hades-credentials/probe")
  (let ((service hades/credentials::*probe-service*)
        (account hades/credentials::*probe-account*))
    #+(or win32 darwin) (signals cred:credential-not-found (cred:fetch-credential service account))
    ;; On Linux with a Secret Service running, the live suite checks the item is absent.
    #+linux (unless (cred:credential-store-available-p)
              (signals cred:credential-store-unavailable (cred:fetch-credential service account)))
    #-(or win32 darwin linux) (signals cred:credential-store-unavailable
                                (cred:fetch-credential service account))))
