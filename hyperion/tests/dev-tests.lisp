;;;; dev-tests.lisp --- what the hot-reload watcher watches (pre-publication issue 134).
;;;;
;;;; The bug: the watcher globbed **/*.lisp, so editing a stylesheet, a template or a data
;;;; file refreshed nothing and the page silently went stale. The fix widens it to
;;;; everything-minus-a-denylist, and the two things worth testing are the ones that make
;;;; widening safe rather than the widening itself:
;;;;
;;;;   - Compiled output stays excluded. COMPILE-FILE writes its fasl beside the source, so
;;;;     a watcher that sees fasls reloads because it just reloaded, forever. That is a
;;;;     termination property, not a tidiness preference.
;;;;   - Only Lisp reaches COMPILE-FILE. Handing it a .css would put a compile error in the
;;;;     browser overlay on every stylesheet edit -- a worse bug than the one being fixed.
;;;;
;;;; These exercise the file-selection and classification functions directly against a real
;;;; temp tree. Driving the whole watcher would mean starting a server and sleeping through
;;;; poll intervals to assert on something these say precisely.

(in-package #:hyperion/tests)

(def-suite dev :description "The hot-reload watcher's file selection." :in hyperion)
(in-suite dev)

(defvar *dev-tree-seq* 0
  "Counter making each temp root unique. Not tmpize-pathname: that CREATES a file, and we
need a DIRECTORY of that name -- which fails with \"a file with the same name already
exists\".")

(defun %dev-tree ()
  "A temp tree shaped like a real project: sources, assets, build output, a VCS directory
and the editor droppings that appear beside a file on every save."
  (let ((root (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "hyperion-dev-test-~D-~D"
                                        (get-universal-time) (incf *dev-tree-seq*))
                                (uiop:temporary-directory)))))
    (flet ((touch (rel)
             (let ((p (merge-pathnames rel root)))
               (ensure-directories-exist p)
               (with-open-file (s p :direction :output :if-exists :supersede)
                 (write-string ";; x" s))
               p)))
      (touch "src/app.lisp")
      (touch "src/app.fasl")            ; our own output, written beside the source
      (touch "src/util.lsp")
      (touch "resources/style.css")
      (touch "resources/page.html")
      (touch "resources/data.json")
      (touch "resources/logo.svg")
      (touch ".git/config")
      (touch ".git/objects/ab/cdef")
      (touch "vendor/libuv/uv.h")
      (touch "dist/app-1.0/app")
      (touch "node_modules/left-pad/index.js")
      (touch "src/.#app.lisp")          ; emacs lock
      (touch "src/app.lisp~")           ; backup
      (touch "src/.DS_Store")
      (touch "logs/server.log")
      root)))

(defmacro %with-dev-tree ((var) &body body)
  `(let ((,var (%dev-tree)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(defun %names (paths) (sort (mapcar #'file-namestring paths) #'string<))

;;; --- the actual bug --------------------------------------------------------

(test assets-are-watched-not-just-lisp
  ;; The reported failure: edit a stylesheet, nothing happens.
  (%with-dev-tree (root)
    (let ((watched (%names (hyperion/dev::%watched-files (list root)))))
      (is (member "style.css" watched :test #'string=) "a stylesheet must be watched")
      (is (member "page.html" watched :test #'string=) "a template must be watched")
      (is (member "data.json" watched :test #'string=) "a data file must be watched")
      (is (member "logo.svg" watched :test #'string=))
      (is (member "app.lisp" watched :test #'string=) "and Lisp still is"))))

(test a-file-type-nobody-anticipated-is-watched
  ;; The reason this is a denylist. An allowlist re-breaks the day someone adds a type,
  ;; and it re-breaks SILENTLY -- edits just quietly stop refreshing.
  (%with-dev-tree (root)
    (let ((p (merge-pathnames "resources/notes.mdx" root)))
      (ensure-directories-exist p)
      (with-open-file (s p :direction :output :if-exists :supersede) (write-string "x" s))
      (is (member "notes.mdx" (%names (hyperion/dev::%watched-files (list root)))
                  :test #'string=)))))

;;; --- termination: the watcher must not watch its own output ----------------

(test compiled-output-is-never-watched
  ;; THE loop: an edit triggers a recompile, the recompile writes a fasl beside the source,
  ;; and a watched fasl is another change. It presents as a hot-reload bug rather than a
  ;; watcher bug, which is why it is worth a test with this name.
  (%with-dev-tree (root)
    (let ((watched (%names (hyperion/dev::%watched-files (list root)))))
      (is (not (member "app.fasl" watched :test #'string=))
          "watching our own fasls makes the reload loop feed itself"))))

(test build-and-vcs-subtrees-are-pruned
  ;; Pruning a subtree is the poller's biggest saving -- it stat-s the tree every interval.
  (%with-dev-tree (root)
    (let ((watched (%names (hyperion/dev::%watched-files (list root)))))
      (is (not (member "config" watched :test #'string=)) ".git must be pruned")
      (is (not (member "cdef" watched :test #'string=)) "...at any depth")
      (is (not (member "uv.h" watched :test #'string=)) "vendor must be pruned")
      (is (not (member "app" watched :test #'string=)) "dist must be pruned")
      (is (not (member "index.js" watched :test #'string=)) "node_modules must be pruned"))))

(test editor-scratch-files-are-ignored
  ;; They appear and vanish on every save; watching them means reloading twice per save.
  (%with-dev-tree (root)
    (let ((watched (%names (hyperion/dev::%watched-files (list root)))))
      (is (not (member ".#app.lisp" watched :test #'string=)))
      (is (not (member "app.lisp~" watched :test #'string=)))
      (is (not (member ".DS_Store" watched :test #'string=))))))

(test logs-and-databases-do-not-trigger-reloads
  ;; A server that writes its own log inside the watched tree would otherwise reload
  ;; whenever it logged -- the same self-feeding shape as the fasl case.
  (%with-dev-tree (root)
    (is (not (member "server.log" (%names (hyperion/dev::%watched-files (list root)))
                     :test #'string=)))))

;;; --- only Lisp is compiled -------------------------------------------------

(test lisp-is-classified-for-compilation-and-assets-are-not
  ;; The split that makes widening safe. COMPILE-FILE on a .css would put a compile error
  ;; in the browser overlay every time somebody edited a stylesheet.
  (is (hyperion/dev::%lisp-file-p "/x/app.lisp"))
  (is (hyperion/dev::%lisp-file-p "/x/app.lsp"))
  (is (hyperion/dev::%lisp-file-p "/x/app.cl"))
  (is (not (hyperion/dev::%lisp-file-p "/x/style.css")))
  (is (not (hyperion/dev::%lisp-file-p "/x/page.html")))
  (is (not (hyperion/dev::%lisp-file-p "/x/data.json")))
  (is (not (hyperion/dev::%lisp-file-p "/x/README"))))

;;; --- the exclusions are configurable, per the *cache-control* precedent ----

(test exclusions-can-be-overridden-per-call
  (%with-dev-tree (root)
    ;; opt vendor/ back IN by narrowing the pruned set
    (let ((watched (%names (hyperion/dev::%watched-files
                            (list root) :excluded-dirs '(".git")))))
      (is (member "uv.h" watched :test #'string=)
          "a caller that wants vendor/ watched should be able to say so"))
    ;; and widen the skipped types
    (let ((watched (%names (hyperion/dev::%watched-files
                            (list root)
                            :excluded-types (cons "css" hyperion/dev:*watch-excluded-types*)))))
      (is (not (member "style.css" watched :test #'string=))))))

(test the-defaults-are-set-and-cover-the-load-bearing-cases
  ;; A default nobody sets is not a default. fasl in particular is not optional.
  (is (member "fasl" hyperion/dev:*watch-excluded-types* :test #'string=)
      "excluding compiled output is a termination requirement")
  (is (member ".git" hyperion/dev:*watch-excluded-directories* :test #'string=))
  (is (member "vendor" hyperion/dev:*watch-excluded-directories* :test #'string=))
  (is (member "dist" hyperion/dev:*watch-excluded-directories* :test #'string=)))

;;; --- the snapshot notices what the watcher is for --------------------------

(test the-snapshot-sees-an-asset-change
  ;; End to end over the two functions the poller actually calls each interval.
  (%with-dev-tree (root)
    (let* ((css (merge-pathnames "resources/style.css" root))
           (before (hyperion/dev::%snapshot (list root))))
      (is (gethash (namestring (truename css)) before) "the asset is in the snapshot")
      (sleep 1.1)                      ; file-write-date has one-second resolution
      (with-open-file (s css :direction :output :if-exists :supersede)
        (write-string "body{color:red}" s))
      (let* ((after (hyperion/dev::%snapshot (list root)))
             (changed (hyperion/dev::%changed-files before after)))
        (is (member (namestring (truename css)) changed :test #'string=)
            "editing a stylesheet must register as a change")))))

;;;; ---------------------------------------------------------------------------
;;;; The hyperion/dev cluster: pre-publication issue 157 pre-publication issue 233 pre-publication issue 234 pre-publication issue 235 pre-publication issue 236 pre-publication issue 237.
;;;;
;;;; Six defects reported by two consuming apps against the loop hyperion/CLAUDE.md calls
;;;; the framework's signature feature. They are not five papercuts: pre-publication issue 157 and pre-publication issue 235 are two
;;;; wrong spellings of ONE parameter, and pre-publication issue 233/pre-publication issue 234/pre-publication issue 237 are all the dev server proceeding
;;;; in a state it could have detected and named.

;;; --- pre-publication issue 235 / pre-publication issue 157: the builder parameter -------------------------------------

(defun bt/build-app ()
  "A named builder, so #'BT/BUILD-APP can be told from an anonymous thunk."
  (lambda (env) (declare (ignore env)) (list 200 '(:content-type "text/plain") '("v1"))))

(test the-app-itself-is-refused-with-an-instruction
  ;; Two independent apps wrote (serve (make-app) ...) and got a bare
  ;; "invalid number of arguments: 0" from inside the watcher; at least one concluded hot
  ;; reload did not support their kind of app. The arity error named nothing -- not the
  ;; parameter, not the thunk requirement, not the file.
  (let ((app (bt/build-app)))                       ; a function of ONE argument
    (signals hyperion/dev:invalid-builder
      (hyperion/dev::%normalize-builder app "MAKE-APP"))
    ;; The report has to be actionable, not merely correct.
    (let ((text (handler-case (progn (hyperion/dev::%normalize-builder app "MAKE-APP") "")
                  (hyperion/dev:invalid-builder (c) (princ-to-string c)))))
      (is (search "MAKE-APP" text) "the message must name the parameter: ~S" text)
      (is (search "1 argument" text))
      (is (search "'make-app" text) "the message must show the right spelling: ~S" text))))

(test a-named-function-object-is-coerced-back-to-its-symbol
  ;; pre-publication issue 157: #'build-app captures the object existing at that instant, so recompiling the
  ;; file that defines it leaves the watcher rebuilding with the pre-edit builder forever.
  ;; A SYMBOL re-resolves on every FUNCALL, which is what the caller plainly meant.
  (is (eq 'bt/build-app (hyperion/dev::%normalize-builder #'bt/build-app))))

(test the-coercion-actually-changes-which-definition-runs
  ;; The control for the test above -- and the only one that shows the DEFECT rather than
  ;; the mechanism. Redefine the builder and check which version each spelling calls.
  ;; FDEFINITION rather than #' for the captured case, deliberately: SBCL late-binds a
  ;; #'foo written in the SAME compiled file as foo's DEFUN, so #' there would quietly
  ;; test nothing. FDEFINITION yields the function object itself, which is what a caller
  ;; hands over from another file -- and that one really does go stale (verified against
  ;; a compile-file/load cycle, which is what WATCH does).
  (let ((captured (fdefinition 'bt/build-app))
        (coerced (hyperion/dev::%normalize-builder #'bt/build-app)))
    (unwind-protect
         (progn
           (setf (fdefinition 'bt/build-app)
                 (lambda () (lambda (env) (declare (ignore env))
                              (list 200 '(:content-type "text/plain") '("v2")))))
           (is (string= "v1" (first (third (funcall (funcall captured) nil))))
               "a captured function object should still be the OLD builder")
           (is (string= "v2" (first (third (funcall (funcall coerced) nil))))
               "the coerced symbol must resolve to the NEW builder -- this is pre-publication issue 157"))
      (setf (fdefinition 'bt/build-app)
            (lambda () (lambda (env) (declare (ignore env))
                         (list 200 '(:content-type "text/plain") '("v1"))))))))

(test an-anonymous-thunk-passes-through-untouched
  ;; It has no name to re-resolve, and a caller who wrote one is not describing a
  ;; definition that can be recompiled. Refusing or rewriting it would break the examples.
  (let ((thunk (lambda () :app)))
    (is (eq thunk (hyperion/dev::%normalize-builder thunk)))))

(test a-symbol-builder-is-already-right
  (is (eq 'bt/build-app (hyperion/dev::%normalize-builder 'bt/build-app))))

;;; --- pre-publication issue 233: an application error must not disconnect the tab -----------------

(test an-app-that-signals-becomes-a-page-carrying-the-poller
  ;; THE mechanism correction. The report read this as "the poller goes into HTML
  ;; responses and a 500 is not one". It is not that (see the test below): the real case
  ;; is an app that SIGNALS, whose condition unwound straight past WRAP-DEV, leaving the
  ;; backend to render a page hyperion never saw -- with no poller, so that tab could
  ;; never learn the server had recovered.
  (let* ((wrapped (hyperion/dev:wrap-dev
                   (lambda (env) (declare (ignore env)) (error "a typo in a handler"))))
         (resp (funcall wrapped (list :path-info "/"))))
    (is (= 500 (first resp)))
    (is (search "text/html" (getf (second resp) :content-type)))
    (let ((body (first (third resp))))
      (is (search "reload" body) "the error page must carry the poller -- that is pre-publication issue 233")
      (is (search "a typo in a handler" body) "and must say what went wrong")
      (is (search "</body>" body) "the poller appends to document.body, so there must be one"))))

(test an-app-that-returns-a-500-was-already-fine
  ;; Recorded because it is what makes the fix above the right one: %MAYBE-INJECT never
  ;; looked at the status, so the report's proposed fix -- extend injection to non-2xx --
  ;; would have changed nothing at all.
  (let* ((wrapped (hyperion/dev:wrap-dev
                   (lambda (env) (declare (ignore env))
                     (list 500 '(:content-type "text/html; charset=utf-8")
                           (list "<html><body>Internal Server Error</body></html>")))))
         (body (first (third (funcall wrapped (list :path-info "/"))))))
    (is (search "reload" body))))

(test the-error-page-escapes-what-it-renders
  ;; The condition's text reaches the page, and in dev it can contain anything a developer
  ;; typed -- including markup that would otherwise break out of the <pre>.
  (let* ((wrapped (hyperion/dev:wrap-dev
                   (lambda (env) (declare (ignore env)) (error "bad <script>alert(1)</script>"))))
         (body (first (third (funcall wrapped (list :path-info "/"))))))
    (is (search "&lt;script&gt;" body))
    (is (null (search "<script>alert(1)</script>" body)))))

(test a-normal-response-is-untouched-by-the-error-path
  (let* ((wrapped (hyperion/dev:wrap-dev
                   (lambda (env) (declare (ignore env))
                     (list 200 '(:content-type "text/html") (list "<html><body>hi</body></html>")))))
         (resp (funcall wrapped (list :path-info "/"))))
    (is (= 200 (first resp)))
    (is (search "hi" (first (third resp))))))

;;; --- pre-publication issue 234: a changed type layout must be reported ---------------------------

(test a-layout-change-warning-is-recognised-and-names-the-type
  ;; SBCL's own wording is the signal, so this test is what stops a rephrasing from
  ;; silently disabling the detection: it fails loudly rather than the feature vanishing.
  (let ((c (make-condition 'simple-warning
                           :format-control "change in instance length of class VIEW:~%The most recently compiled length: 2"
                           :format-arguments nil)))
    (is (string= "VIEW" (hyperion/dev::%redefined-type-name c)))))

(test an-ordinary-warning-is-not-mistaken-for-a-layout-change
  (is (null (hyperion/dev::%redefined-type-name
             (make-condition 'simple-warning :format-control "redefining FOO"
                                             :format-arguments nil)))))

;;; --- pre-publication issue 237: a root with no Lisp in it ----------------------------------------

(test a-watched-root-with-no-lisp-is-noticed
  ;; NOT the reported case -- that repo's src/ held a populated shared core, so this stays
  ;; silent there and the docstring is what addresses it. This catches the empty root.
  (let ((root (uiop:ensure-directory-pathname
               (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "hyp-dev-empty-~D/" (random 100000))
                                 (uiop:temporary-directory))))))
    (unwind-protect
         (progn
           (ensure-directories-exist root)
           (with-open-file (s (merge-pathnames "README.md" root) :direction :output
                                                                 :if-exists :supersede)
             (write-string "no lisp here" s))
           (is (notany #'hyperion/dev::%lisp-file-p
                       (hyperion/dev::%watched-files (list root)))))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

;;; --- the no-Lisp warning is about the watch set, not each root (#134) ---------------

(defun %dev-root-with (file)
  "A fresh directory holding one file named FILE."
  (let ((root (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "hyp-dev-134-~36R/" (random (expt 2 40) (make-random-state t)))
                                (uiop:temporary-directory)))))
    (ensure-directories-exist root)
    (with-open-file (s (merge-pathnames file root) :direction :output :if-exists :supersede)
      (write-string "x" s))
    root))

(defun %dev-warnings-and-no-lisp (roots)
  "Call %NOTE-ROOTS-WITHOUT-LISP on ROOTS; return (values warning-messages no-lisp-roots)."
  (let ((warnings '()))
    (let ((no-lisp (handler-bind ((warning (lambda (w)
                                             (push (princ-to-string w) warnings)
                                             (muffle-warning w))))
                     (hyperion/dev::%note-roots-without-lisp
                      roots hyperion/dev:*watch-excluded-directories*
                      hyperion/dev:*watch-excluded-types*))))
      (values (nreverse warnings) no-lisp))))

(test an-asset-only-root-beside-a-lisp-root-does-not-warn
  ;; The reported case: :SYSTEM with Lisp, plus an asset directory passed through :PATHS.
  ;; It used to warn on every boot, for a configuration that works.
  (let ((src (%dev-root-with "app.lisp"))
        (assets (%dev-root-with "site.css")))
    (unwind-protect
         (multiple-value-bind (warnings no-lisp) (%dev-warnings-and-no-lisp (list src assets))
           (is (null warnings) "no warning when some watched root has Lisp, got ~S" warnings)
           (is (equal (list assets) no-lisp) "the asset-only root is still identified")
           (is (search "(no .lisp)" (second (hyperion/dev::%root-listing (list src assets) no-lisp)))
               "and the banner marks it, instead of a warning")
           (is (not (search "(no .lisp)" (first (hyperion/dev::%root-listing (list src assets) no-lisp))))))
      (ignore-errors (uiop:delete-directory-tree src :validate t))
      (ignore-errors (uiop:delete-directory-tree assets :validate t)))))

(test a-single-root-with-no-lisp-still-warns-once
  ;; pre-publication issue 237's case, which the narrowing must keep: :SYSTEM resolved somewhere with no
  ;; Lisp, so the watcher would never fire.
  (let ((root (%dev-root-with "README.md")))
    (unwind-protect
         (let ((warnings (%dev-warnings-and-no-lisp (list root))))
           (is (= 1 (length warnings)) "exactly one warning, got ~S" warnings)
           (is (search (namestring root) (or (first warnings) "")) "naming the root"))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

(test several-roots-with-no-lisp-warn-once-not-once-each
  (let ((a (%dev-root-with "a.css"))
        (b (%dev-root-with "b.json")))
    (unwind-protect
         (let ((warnings (%dev-warnings-and-no-lisp (list a b))))
           (is (= 1 (length warnings)) "one warning for the watch set, got ~S" warnings)
           (is (and (search (namestring a) (or (first warnings) ""))
                    (search (namestring b) (or (first warnings) "")))
               "naming every root"))
      (ignore-errors (uiop:delete-directory-tree a :validate t))
      (ignore-errors (uiop:delete-directory-tree b :validate t)))))
