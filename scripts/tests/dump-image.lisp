;;;; dump-image.lisp --- a dumped image reads its environment when it starts (#107)
;;;;
;;;; The tests take the shape of #107's measurement: an image is dumped under one
;;;; environment and run under another, and it reports its temporary directory and where a
;;;; fasl would go. With scripts/dump-image.lisp it must report the environment it RUNS in.
;;;;
;;;; THE CONTROL IS THE BARE DUMP, run through the same fixture. It must report the
;;;; environment it was DUMPED in, which is the defect. A fixture that could not reproduce
;;;; the defect would pass the first test for the wrong reason, for example if the child
;;;; never computed its translations before the dump and so had nothing to freeze.
;;;;
;;;; bin/cons and every desktop app are dumped by this one function, and the last test
;;;; checks that both callers still use it. Dumping bin/cons or a desktop app here would take
;;;; minutes per run and would test the same call.

(in-package #:checkers/tests)

;;; The suite is named here as well as in checkers.lisp. FiveAM's current suite does not carry
;;; over from one file to the next, so without this line the tests below were registered but
;;; were not in `checkers', and the gate's run of that suite did not run them: its count stayed
;;; at 128 on the first gate run of this change, where 142 was predicted.
(in-suite checkers)

(defparameter +cache-overrides+ '("ASDF_OUTPUT_TRANSLATIONS")
  "Variables that override where fasls go, removed from both environments of a test.

scripts/with-mode.lisp sets ASDF_OUTPUT_TRANSLATIONS for the gate's release-mode run, so every
child of that run inherits it, and an image honouring its run-time environment then puts fasls
where that variable says rather than under XDG_CACHE_HOME. That is correct behaviour, and it
made the first version of these tests fail on the release-mode leg only, because the fixture
controlled XDG_CACHE_HOME and not this.")

(defun %environment-with (pairs)
  "This process's environment with PAIRS, (NAME . VALUE), replacing any existing NAME, and
without the variables in +CACHE-OVERRIDES+."
  (append (mapcar (lambda (p) (format nil "~A=~A" (car p) (cdr p))) pairs)
          (remove-if (lambda (e)
                       (or (some (lambda (p) (uiop:string-prefix-p (format nil "~A=" (car p)) e)) pairs)
                           (some (lambda (name) (uiop:string-prefix-p (format nil "~A=" name) e))
                                 +cache-overrides+)))
                     (sb-ext:posix-environ))))

(defun %where-it-looks (temp cache)
  "The variables that decide a temporary directory and a fasl cache, on every OS."
  (let ((temp (uiop:native-namestring temp))
        (cache (uiop:native-namestring cache)))
    (list (cons "TEMP" temp) (cons "TMP" temp) (cons "TMPDIR" temp)
          (cons "XDG_CACHE_HOME" cache))))

(defun %dump-then-run (dump-form)
  "Dump an image in a fresh tree with the forms DUMP-FORM returns for the image's path, under one environment, then run it under
another. Returns (values RUN-OUTPUT DUMP-CODE RUN-CODE DUMP-OUTPUT).

DUMP-FORM returns a LIST of forms, each passed to the child as its own `--eval', because a
form that loads a file and then names a package from it cannot be read in one piece: the
reader meets the package name before the load has run.

The dump-time directories are named `dumptemp' and `dumpcache', the run-time ones `runtemp'
and `runcache', inside a directory no other run shares, so the output can be searched for a
name without depending on how a path is spelled."
  (let* ((tree (%fresh-tree))
         (dirs (loop for name in '("dumptemp/" "dumpcache/" "runtemp/" "runcache/")
                     collect (ensure-directories-exist (merge-pathnames name tree))))
         (probe (merge-pathnames "probe.lisp" tree))
         (image (merge-pathnames (if (uiop:os-windows-p) "probe.exe" "probe") tree))
         (dump-out (make-string-output-stream))
         (run-out (make-string-output-stream)))
    (%write probe (%lines "(defpackage #:dump-probe (:use #:cl))"
                          "(in-package #:dump-probe)"
                          "(defun main ()"
                          "  (format t \"~&TEMP ~A~%\" (uiop:native-namestring (uiop:temporary-directory)))"
                          "  (format t \"~&FASL ~A~%\" (uiop:native-namestring (asdf:apply-output-translations (merge-pathnames \"x.lisp\" (uiop:temporary-directory)))))"
                          "  (finish-output)"
                          "  (uiop:quit 0))"))
    (let ((dump-code
            (nth-value 2 (uiop:run-program
                          (append
                           (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                 "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                                 "--eval" "(require :asdf)"
                                 "--eval" (format nil "(load ~S)" (uiop:native-namestring probe))
                                 ;; What a real build has done by the time it dumps: asked for
                                 ;; its temporary directory and compiled something, so the
                                 ;; translations are computed. Without this the child would
                                 ;; have nothing to freeze, and the control could not fail.
                                 "--eval" "(progn (uiop:temporary-directory) (asdf:apply-output-translations (merge-pathnames \"x.lisp\" (uiop:temporary-directory))))")
                           (mapcan (lambda (f) (list "--eval" f))
                                   (funcall dump-form (uiop:native-namestring image))))
                          :output dump-out :error-output dump-out :ignore-error-status t
                          :environment (%environment-with (%where-it-looks (first dirs) (second dirs))))))
          (run-code
            (and (probe-file image)
                 (nth-value 2 (uiop:run-program
                               (list (uiop:native-namestring image))
                               :output run-out :error-output run-out :ignore-error-status t
                               :environment (%environment-with (%where-it-looks (third dirs) (fourth dirs))))))))
      (uiop:delete-directory-tree tree :validate t :if-does-not-exist :ignore)
      (values (get-output-stream-string run-out) dump-code run-code (get-output-stream-string dump-out)))))

(test dump-executable-takes-temp-and-cache-from-where-it-runs
  "#107: an image dumped by scripts/dump-image.lisp reports the run-time TEMP and cache."
  (multiple-value-bind (out dump-code run-code dump-out)
      (%dump-then-run (lambda (image)
                        (list (format nil "(load ~S)" (uiop:native-namestring (merge-pathnames "dump-image.lisp" *scripts*)))
                              (format nil "(ouranos-dump:dump-executable ~S 'dump-probe::main)" image))))
    (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
    (is (eql 0 run-code) "the image did not run cleanly:~%~A" out)
    (is (search "runtemp" out) "its temporary directory must be the run-time TEMP:~%~A" out)
    (is (search "runcache" out) "its fasls must go to the run-time XDG_CACHE_HOME:~%~A" out)
    (is (not (search "dumptemp" out)) "it still reports the TEMP it was dumped under:~%~A" out)
    (is (not (search "dumpcache" out)) "it still reports the cache it was dumped under:~%~A" out)))

(test bare-dump-keeps-temp-and-cache-from-where-it-was-dumped
  "The control: a bare save-lisp-and-die, through the same fixture, keeps the dump-time
TEMP and cache. This is the defect #107 measured, and it shows the fixture can see it."
  (multiple-value-bind (out dump-code run-code dump-out)
      (%dump-then-run (lambda (image)
                        (list (format nil "(sb-ext:save-lisp-and-die ~S :toplevel 'dump-probe::main :executable t :save-runtime-options t)"
                                      image))))
    (is (eql 0 dump-code) "the dump failed:~%~A" dump-out)
    (is (eql 0 run-code) "the image did not run cleanly:~%~A" out)
    (is (search "dumptemp" out) "a bare dump must keep the dump-time TEMP, or this fixture cannot see #107:~%~A" out)
    (is (search "dumpcache" out) "a bare dump must keep the dump-time cache, or this fixture cannot see #107:~%~A" out)))

(test bin-cons-and-desktop-apps-dump-through-dump-executable
  "bootstrap.lisp (bin/cons) and build-desktop-app.lisp (every desktop app) must both dump
through ouranos-dump:dump-executable, and neither may call save-lisp-and-die itself, so the
two tests above describe what those two produce."
  (dolist (file '("bootstrap.lisp" "scripts/build-desktop-app.lisp"))
    (let ((text (uiop:read-file-string (merge-pathnames file td-root))))
      (is (search "ouranos-dump:dump-executable" text) "~A must dump through ouranos-dump:dump-executable" file)
      (is (not (search "(sb-ext:save-lisp-and-die" text)) "~A calls save-lisp-and-die itself, so its image skips UIOP's hooks" file))))

(defun %template-forms (text)
  "The top-level forms of a cons template's build script TEXT, read with {{name}} replaced by a
placeholder. A symbol in a package this image does not have (ql:quickload, the app's main) is
read into a scratch package, which is enough to compare symbol names."
  (let ((pkg (or (find-package "TEMPLATE-FORMS-SCRATCH") (make-package "TEMPLATE-FORMS-SCRATCH" :use '())))
        (text (uiop:frob-substrings text '("{{name}}") "template-app")))
    (handler-bind ((sb-int:simple-reader-package-error
                     (lambda (c) (declare (ignore c)) (invoke-restart 'continue))))
      (with-input-from-string (s text)
        (let ((*package* pkg) (*read-eval* nil))
          (loop for form = (read s nil s) until (eq form s) collect form))))))

(defun %call-named-p (form name)
  (and (consp form) (symbolp (car form)) (string= (symbol-name (car form)) name)))

(defun %template-hook-order (text)
  "(values DUMP-HOOK-FIRST RESTORE-HOOK-FIRST) for a template build script TEXT, from its forms
rather than its characters, so a comment or a string cannot stand in for a call.
DUMP-HOOK-FIRST: a top-level (uiop:call-image-dump-hook) comes before the top-level
(sb-ext:save-lisp-and-die ...). RESTORE-HOOK-FIRST: the first form of that call's :toplevel
lambda is (uiop:call-image-restore-hook), and the lambda calls main after it."
  (let* ((forms (%template-forms text))
         (hook (position-if (lambda (f) (%call-named-p f "CALL-IMAGE-DUMP-HOOK")) forms))
         (dump (position-if (lambda (f) (%call-named-p f "SAVE-LISP-AND-DIE")) forms))
         (toplevel (and dump (getf (cddr (nth dump forms)) :toplevel)))
         (body (and (%call-named-p toplevel "LAMBDA") (cddr toplevel)))
         (main (position-if (lambda (f) (%call-named-p f "MAIN")) body)))
    (values (and hook dump (< hook dump) t)
            (and body main (%call-named-p (first body) "CALL-IMAGE-RESTORE-HOOK") (> main 0) t))))

(test cons-templates-dump-with-uiops-hooks
  "The build script every `cons init' project gets must run UIOP's dump hook before its dump
and the restore hook first in its toplevel (#107). A generated project cannot load
scripts/dump-image.lisp, which lives in this tree, so each template writes the two calls
itself, and this checks all three. The behaviour of those two calls is what the tests above
measure."
  ;; Order, not only presence (review of #285), and read from the forms (review of #328): a
  ;; restore hook called after main, or a dump hook after the dump, would be found by a
  ;; presence check, and a commented-out call before main would satisfy a check on the text.
  (dolist (template '("agent" "cli" "web"))
    (let ((file (format nil "cons/templates/~A/files/scripts/build-{{name}}.lisp" template)))
      (multiple-value-bind (dump-ok restore-ok)
          (%template-hook-order (uiop:read-file-string (merge-pathnames file td-root)))
        (is-true dump-ok "~A must call uiop:call-image-dump-hook before save-lisp-and-die" file)
        (is-true restore-ok "~A's toplevel must call uiop:call-image-restore-hook first, then main" file)))))

(test template-hook-order-is-read-from-forms-not-text
  "The control for the test above: a template whose restore hook is moved after main, with a
commented-out call left before main, and one whose dump hook is only in a string, must fail."
  (let ((text (uiop:read-file-string
               (merge-pathnames "cons/templates/agent/files/scripts/build-{{name}}.lisp" td-root))))
    (is-true (nth-value 1 (%template-hook-order text)) "the unmodified template must pass")
    (let ((moved (uiop:frob-substrings
                  text '("             (uiop:call-image-restore-hook)
             ({{name}}:main)))")
                  (format nil "             ;; (uiop:call-image-restore-hook)~%             ({{name}}:main)~%             (uiop:call-image-restore-hook)))"))))
      (is (not (equal moved text)) "the control must have changed the template")
      (is-false (nth-value 1 (%template-hook-order moved))
                "a restore hook after main, with a comment before it, must fail"))
    (let ((stringed (uiop:frob-substrings text '("(uiop:call-image-dump-hook)")
                                          "\"(uiop:call-image-dump-hook)\"")))
      (is (not (equal stringed text)) "the control must have changed the template")
      (is-false (nth-value 0 (%template-hook-order stringed))
                "a dump hook that is only a string must fail"))))
