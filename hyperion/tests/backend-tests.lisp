;;;; backend-tests.lisp --- which HTTP backend gets chosen (#139).
;;;;
;;;; Hyperion declares no HTTP server; the application does. So the interesting logic is
;;;; "given what the operator asked for and what is actually in the image, which backend do
;;;; we start" -- and it is tested through %CHOOSE-SERVER, which takes both as arguments.
;;;; Testing DEFAULT-SERVER directly would mean mutating HYPERION_SERVER in the environment
;;;; of the process running the suite, and asserting on whichever handlers happened to be
;;;; loaded by everything else in the image -- a test whose result depends on its neighbours.
;;;;
;;;; Separate from server-tests.lisp, which owns the blocking entry point (#124): that file
;;;; asks what a running server does, this one asks which server we run at all.

(in-package #:hyperion/tests)

(def-suite backend :description "Choosing an HTTP backend from what the image loaded." :in hyperion)
(in-suite backend)

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
  ;;
  ;; ONE check, not one per backend: this suite runs both alone (`asdf:test-system`, where
  ;; only the examples' handler is loaded) and inside verify-tree (where praxeon/web has
  ;; loaded the other one too), and a per-backend loop makes the tree's total check count
  ;; wobble with the image. That count is the evidence verify-tree rests on, so it must not
  ;; depend on the neighbours.
  (let ((missing (remove-if (lambda (backend)
                              (find-package (cdr (assoc backend srv::+backends+))))
                            (srv:available-servers))))
    (is (null missing)
        "reported as available, but the handler package is not loaded: ~S" missing)))

;;; --- the native backend (#117, commit 5) -----------------------------------
;;;
;;; Pure tests only, here. Whether :UV actually SERVES anything is asked in
;;; hyperion/server-uv/tests, which is the only suite that may load a system needing libuv.
;;; What belongs here is the choosing, which is pure and is where the commit-6 boundary
;;; lives: :UV is in the table and deliberately not at the head of it.

(test uv-is-known-but-not-preferred
  ;; The whole of commit 5 in one assertion. Moving :UV to the head of +BACKENDS+ is
  ;; commit 6 -- the demotion of Hunchentoot and Woo to opt-in -- and it is a decision
  ;; someone makes, not something that drifts in behind a reordering.
  (is-true (assoc :uv srv::+backends+) ":uv must be a known backend")
  (is (not (eq :uv (car (first srv::+backends+))))
      ":uv must NOT head the table -- moving it there IS the commit-6 demotion of
Hunchentoot and Woo to opt-in, and that should be a decision someone makes rather than
something that arrives behind an innocent-looking reorder")
  (is (eq :hunchentoot (srv::%choose-server nil '(:hunchentoot :uv)))
      "with both loaded and nothing requested, the Clack backend still wins in commit 5"))

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
;;; loaded in this image -- so this is where "what happens when it is missing" has a real
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
