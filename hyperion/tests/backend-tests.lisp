;;;; backend-tests.lisp --- which HTTP backend gets chosen (pre-publication issue 139, #710, #373).
;;;;
;;;; Hyperion declares no HTTP server; the application does. So the interesting logic is
;;;; "given what the operator asked for and what is actually in the image, which backend do
;;;; we start" -- and it is tested through %CHOOSE-SERVER, which takes both as arguments.
;;;; Testing DEFAULT-SERVER directly would mean mutating HYPERION_SERVER in the environment
;;;; of the process running the suite, and asserting on whichever handlers happened to be
;;;; loaded by everything else in the image -- a test whose result depends on its neighbours.
;;;;
;;;; ITS OWN SYSTEM, hyperion/backends/tests, with no server in the image (#373). The tree's
;;;; suites used to load clack-handler-hunchentoot; since #373 no system in the tree declares a
;;;; third-party Clack handler, and hyperion/tests loads hyperion/server-uv. So the two things
;;;; this file has to see absent -- hyperion/server-uv, and every Clack handler -- are absent
;;;; here. A Clack handler is stood in for by a package with the name +BACKENDS+ gives it,
;;;; because the package is the whole of what AVAILABLE-SERVERS reads (WITH-STAND-IN-PACKAGES).
;;;; That a real Clack handler is then started through START's Clack path is checked in
;;;; hyperion/tests (server-tests.lisp, %WITH-CLACK-PATH), with hyperion/clack-handler-uv as
;;;; the handler.

(cl:defpackage #:hyperion/backends/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv #:hyperion/server))
  (:export #:run-tests #:backend))

(in-package #:hyperion/backends/tests)

(def-suite backend :description "Choosing an HTTP backend from what the image loaded.")
(in-suite backend)

(defun run-tests ()
  "Run the suite; return T on success (for `asdf:test-system`)."
  (run! 'backend))

(defun call-with-stand-in-packages (names function)
  "Call FUNCTION with a package of each of NAMES present, then delete the ones this call made.
A name that already names a package is left alone, and the test that relies on it being absent
says so with its own check."
  (let ((made '()))
    (unwind-protect
         (progn
           (dolist (name names)
             (unless (find-package name)
               (push (make-package name :use '()) made)))
           (funcall function))
      (mapc #'delete-package made))))

(defmacro with-stand-in-packages ((&rest names) &body body)
  `(call-with-stand-in-packages (list ,@names) (lambda () ,@body)))

(test picks-the-first-available-backend
  (is (eq :woo (srv::%choose-server nil '(:woo :hunchentoot))))
  (is (eq :hunchentoot (srv::%choose-server nil '(:hunchentoot)))))

(test no-backend-is-an-error-not-a-guess
  ;; The old code returned :woo on Unix whether or not Woo was there, so an app that
  ;; declared nothing failed later, inside clackup, in Clack's vocabulary. This is the
  ;; failure the app author can act on.
  (signals srv:no-server-backend (srv::%choose-server nil '())))

(test an-override-is-honoured-when-it-is-loaded
  (is (eq :hunchentoot (srv::%choose-server :hunchentoot '(:woo :hunchentoot)))))

(test an-override-we-know-and-lack-never-falls-back
  ;; Falling back would start a server the operator did not ask for -- which in production
  ;; reads as "the config was ignored", and is worse than refusing to start.
  (signals srv:no-server-backend (srv::%choose-server :woo '(:hunchentoot))))

(test an-override-we-do-not-know-is-passed-through
  ;; +BACKENDS+ is the list of handlers whose package we can name, not the list Clack
  ;; supports. A backend we have never heard of is the operator's business.
  (is (eq :fcgi (srv::%choose-server :fcgi '(:hunchentoot)))))

(test available-servers-reports-only-what-is-loaded
  ;; The invariant, whatever else the image happens to have loaded: every backend reported
  ;; has its handler PACKAGE present. Presence of the package is the test because a dumped
  ;; image cannot asdf:load-system a handler that was never compiled into it.
  (let ((missing (remove-if (lambda (backend)
                              (find-package (cdr (assoc backend srv::+backends+))))
                            (srv:available-servers))))
    (is (null missing)
        "reported as available, but the handler package is not loaded: ~S" missing)))

;;; --- a Clack handler an app declares, stood in for (#373) ------------------------------
;;;
;;; No system in the tree declares clack-handler-woo or clack-handler-hunchentoot any more,
;;; and an app that wants one adds it to its own :depends-on. What hyperion does with that is
;;; read the handler's PACKAGE, so these tests make that package and nothing else. The first
;;; check in each is that this image has no handler loaded: if something ever loads one here,
;;; the tests say so rather than passing on the real handler.

(test no-clack-handler-is-loaded-in-this-image
  (is (null (srv:available-servers))
      "this suite's image is meant to load no server, but has: ~S" (srv:available-servers)))

(test a-loaded-clack-handler-is-offered-and-chosen
  "An app that adds clack-handler-hunchentoot and nothing else gets Hunchentoot, chosen as the
preferred backend, and HYPERION_SERVER=hunchentoot gets it as requested."
  (is-false (find-package "CLACK.HANDLER.HUNCHENTOOT"))
  (with-stand-in-packages ("CLACK.HANDLER.HUNCHENTOOT")
    (is (equal '(:hunchentoot) (srv:available-servers)))
    (is (equal '(:hunchentoot :preferred)
               (multiple-value-list (srv::%choose-server nil (srv:available-servers)))))
    (is (equal '(:hunchentoot :requested)
               (multiple-value-list (srv::%choose-server :hunchentoot (srv:available-servers))))))
  (is (null (srv:available-servers)) "the stand-in package was not removed"))

(test with-two-clack-handlers-loaded-woo-is-preferred-and-either-can-be-requested
  "The order of +BACKENDS+ is the preference: Woo before Hunchentoot, both after :uv."
  (with-stand-in-packages ("CLACK.HANDLER.WOO" "CLACK.HANDLER.HUNCHENTOOT")
    (is (equal '(:woo :hunchentoot) (srv:available-servers)))
    (is (eq :woo (srv::%choose-server nil (srv:available-servers))))
    (is (eq :hunchentoot (srv::%choose-server :hunchentoot (srv:available-servers))))))

(test uv-is-preferred-over-a-loaded-clack-handler
  (with-stand-in-packages ("HYPERION/SERVER-UV" "CLACK.HANDLER.HUNCHENTOOT")
    (is (equal '(:uv :hunchentoot) (srv:available-servers)))
    (is (equal '(:uv :preferred)
               (multiple-value-list (srv::%choose-server nil (srv:available-servers)))))
    (is (equal '(:hunchentoot :requested)
               (multiple-value-list (srv::%choose-server :hunchentoot (srv:available-servers))))
        "HYPERION_SERVER=hunchentoot selects the Clack handler over :uv")))

(test a-requested-clack-handler-that-is-not-loaded-is-refused
  "HYPERION_SERVER=woo in an image that loaded only Hunchentoot does not fall back."
  (with-stand-in-packages ("CLACK.HANDLER.HUNCHENTOOT")
    (signals srv:no-server-backend (srv::%choose-server :woo (srv:available-servers)))))

(test woo-s-status-table-is-completed-without-changing-its-own-lines
  "#372: START adds a status line to Woo's table for each code from 100 to 599 that it lacks,
so that a 429 is not sent as an empty 500. Woo is not loaded in the tree any more, so its table
is stood in for: a package WOO.RESPONSE whose *STATUS-LINE* holds two of Woo's own lines."
  (is-false (find-package "WOO.RESPONSE"))
  (is (null (srv:complete-woo-status-lines)) "without Woo there is nothing to complete")
  (with-stand-in-packages ("WOO.RESPONSE")
    (let* ((symbol (intern "*STATUS-LINE*" "WOO.RESPONSE"))
           (table (make-hash-table))
           (ok (sb-ext:string-to-octets (format nil "HTTP/1.1 200 OK~C~C" #\Return #\Linefeed)))
           (not-found (sb-ext:string-to-octets
                       (format nil "HTTP/1.1 404 Not Found~C~C" #\Return #\Linefeed))))
      (setf (gethash 200 table) ok (gethash 404 table) not-found)
      (proclaim (list 'special symbol))
      (setf (symbol-value symbol) table)
      (let ((added (srv:complete-woo-status-lines)))
        (is (= 498 (length added)) "every code from 100 to 599 but the two Woo had")
        (is (null (set-difference '(425 429 431 511 599) added))))
      (is (eq ok (gethash 200 table)) "a line Woo had was replaced")
      (is (eq not-found (gethash 404 table)) "a line Woo had was replaced")
      (is (equalp (sb-ext:string-to-octets
                   (format nil "HTTP/1.1 429 Too Many Requests~C~C" #\Return #\Linefeed))
                  (gethash 429 table)))
      (is (equalp (sb-ext:string-to-octets (format nil "HTTP/1.1 599 ~C~C" #\Return #\Linefeed))
                  (gethash 599 table))
          "a code nobody registered gets an empty reason phrase")
      (is (null (srv:complete-woo-status-lines)) "completing the table again adds nothing"))))

;;; --- the native backend (pre-publication issue 117, #710) ------------------------------------
;;;
;;; Pure tests only, here. Whether :UV actually SERVES anything is asked in
;;; hyperion/server-uv/tests and hyperion/tests, which load hyperion/server-uv. What belongs
;;; here is the choosing: :UV heads the table (#710), and is skipped with a reason
;;; when libuv does not load.

(test uv-is-preferred-when-libuv-loads
  (is (eq :uv (car (first srv::+backends+))) ":uv heads the table")
  (is (equal '(:uv :preferred)
             (multiple-value-list (srv::%choose-server nil '(:uv :hunchentoot))))))

(test uv-is-skipped-with-a-reason-when-libuv-does-not-load
  "Control: the same AVAILABLE as the test above, with UV-PROBLEM set."
  (is (equal '(:hunchentoot :libuv-unavailable)
             (multiple-value-list
              (srv::%choose-server nil '(:uv :hunchentoot) :uv-problem "no libuv here"))))
  (is (equal '(:hunchentoot :preferred)
             (multiple-value-list
              (srv::%choose-server nil '(:hunchentoot) :uv-problem "no libuv here")))
      "with server-uv not loaded, libuv is not the reason"))

(test uv-alone-is-chosen-even-when-libuv-does-not-load
  ;; With nothing to fall back to, START is left to fail with libuv's own instructions.
  (is (equal '(:uv :libuv-unavailable)
             (multiple-value-list (srv::%choose-server nil '(:uv) :uv-problem "no libuv here")))))

(test an-override-decides-whatever-libuv-does
  (is (equal '(:uv :requested)
             (multiple-value-list
              (srv::%choose-server :uv '(:uv :hunchentoot) :uv-problem "no libuv here"))))
  (is (equal '(:hunchentoot :requested)
             (multiple-value-list (srv::%choose-server :hunchentoot '(:uv :hunchentoot))))
      "HYPERION_SERVER=hunchentoot keeps Hunchentoot when libuv loads"))

(test the-libuv-probe-returns-the-error-message-or-nil
  (is (null (srv::%libuv-problem (lambda () t))))
  (is (equal "libuv 1.40 is too old"
             (srv::%libuv-problem (lambda () (error "libuv 1.40 is too old"))))))

(test uv-gets-two-workers-by-default-and-the-others-none
  (is (eql 2 (srv:default-workers :uv)))
  (is (null (srv:default-workers :hunchentoot)))
  (is (null (srv:default-workers :woo))))

(test uv-is-chosen-when-it-is-all-there-is
  (is (eq :uv (srv::%choose-server nil '(:uv)))))

(test uv-is-honoured-when-asked-for
  (is (eq :uv (srv::%choose-server :uv '(:hunchentoot :uv)))))

(test asking-for-uv-without-it-loaded-never-falls-back
  ;; Same rule as every other known backend: answering on a server the operator did not
  ;; ask for reads in production as "the config was ignored".
  (signals srv:no-server-backend (srv::%choose-server :uv '(:hunchentoot))))

(test native-backend-p-tells-ours-from-clacks
  (is-true (srv:native-backend-p :uv))
  (is-false (srv:native-backend-p :hunchentoot))
  (is-false (srv:native-backend-p :woo))
  (is-false (srv:native-backend-p :fcgi) "a backend we never heard of is not ours"))

;;; --- the absent-package boundary -------------------------------------------
;;;
;;; THIS SUITE IS THE ONLY PLACE THESE CAN BE ASKED, and that is the point of putting them
;;; here rather than beside the rest of the native-server tests. hyperion/server-uv is NOT
;;; loaded in this image (hyperion/tests loads it since #373) -- so this is where "what happens when it is missing" has a real
;;; answer. In its own suite the package always exists and the question is unaskable; that
;;; suite passed 79/79 while STOP was broken for every Clack server in the tree.

(test asking-whether-a-handler-is-native-is-safe-without-the-system
  "FIND-SYMBOL given a package NAME that does not exist SIGNALS -- it does not return NIL --
and STOP asks this about every handler it is given."
  (is-false (find-package "HYPERION/SERVER-UV")
            "if this image ever loads it, these two tests stop asking anything")
  (finishes (srv::%uv-server-p :a-clack-handler))
  (is-false (srv::%uv-server-p :a-clack-handler)))

(test starting-uv-without-the-system-gives-the-framework-error
  "Not `does not designate any package'. The operator asked for a backend that is not in
the image, which is exactly what NO-SERVER-BACKEND says and tells them how to fix."
  (signals srv:no-server-backend (srv::%uv-call "START" (lambda (env) env))))

(test hunchentoot-is-built-without-its-ssl-half-on-every-platform
  "#337: hyperion.asd pushes :hunchentoot-no-ssl on every platform, not only Windows, so an app
that adds clack-handler-hunchentoot gets a Hunchentoot that does not load cl+ssl and OpenSSL. A
desktop bundle that loaded OpenSSL at build time reopens it at startup and exits on a Mac
without Homebrew (#332). Before #373 this test also checked that Hunchentoot's SSL-ACCEPTOR was
not defined; no system in the tree loads Hunchentoot now, so only the feature can be checked."
  (is (member :hunchentoot-no-ssl *features*)))
