;;;; release-settings.lisp --- the release options of build-desktop-app.lisp (#408)
;;;;
;;;; scripts/release-settings.lisp parses --product, --display-name, --public-key-file,
;;;; --update-source, --default-channel and --release, and sets hyperion/update's variables in the
;;;; image before the dump. The first tests run its parser; the last builds a small app with every
;;;; option, runs it, and reads the settings back out of the running image.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "release-settings.lisp" *scripts*)))

(defun %shaped-key (char)
  "Text with a public key's shape (43 base64 characters and =), for the parser, which checks the
shape only. Not a key a signature would verify against."
  (concatenate 'string (make-string 43 :initial-element char) "="))

(defun %release (argv &key (name "probe") env)
  "Parse ARGV with --name NAME, and an environment holding only ENV, an alist."
  (ouranos-release-settings:parse-release-settings
   argv :name name :getenv (lambda (var) (cdr (assoc var env :test #'string=)))))

(defun %refused (argv &rest keys)
  "The reason ARGV is refused, or NIL if it is not."
  (handler-case (progn (apply #'%release argv keys) nil)
    (ouranos-release-settings:release-settings-refused (e) (princ-to-string e))))

(test with-no-option-every-release-setting-is-left-unset
  ;; An app may set any of these in its own source; a build that gives no option must not
  ;; replace them (hub's review of #568: --name used to replace an app's own *app-name*).
  (let ((s (%release '())))
    (dolist (key '(:product :display-name :public-key :sources :channel :release))
      (is (null (getf s key)) "~S is ~S" key (getf s key)))))

(test release-settings-read-every-option
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let* ((key-file (%bytes-file (merge-pathnames "updater.pub" tree)
                                       (format nil "# the release key~%~%~A~%" (%shaped-key #\A))))
                (s (%release (list "--product" "probe" "--display-name" "Probe App"
                                   "--public-key-file" (uiop:native-namestring key-file)
                                   "--update-source" "s3=https://bucket.example/updates/probe"
                                   "--update-source" "github=https://github.com/o/r/releases/download/probe-beta/"
                                   "--default-channel" "beta" "--release"))))
           (is (equal "Probe App" (getf s :display-name)))
           (is (equal (%shaped-key #\A) (getf s :public-key)) "the key file's one key, without the comment")
           (is (equal '(("S3-SOURCE" . "https://bucket.example/updates/probe/")
                        ("GITHUB-RELEASE-SOURCE" . "https://github.com/o/r/releases/download/probe-beta/"))
                      (getf s :sources))
               "the sources in the order given, each URL ending in /")
           (is (equal "beta" (getf s :channel)))
           (is-true (getf s :release)))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test the-public-key-variable-is-read-only-for-a-release-build
  (let ((env `((,ouranos-release-settings:*public-key-variable* . ,(format nil " ~A " (%shaped-key #\B))))))
    (is (equal (%shaped-key #\B)
               (getf (%release '("--release" "--update-source" "github=https://x.example/") :env env)
                     :public-key))
        "with --release, the variable's key, trimmed")
    (is (null (getf (%release '() :env env) :public-key))
        "without --release, the variable is not read, so a key the app set itself stays"))
  (is (search "needs the public key"
              (%refused '("--release" "--update-source" "github=https://x.example/")
                        :env `((,ouranos-release-settings:*public-key-variable* . ""))))
      "an empty variable is no key"))

(test release-settings-refuse-what-they-cannot-use
  (let ((tree (%fresh-tree)))
    (unwind-protect
         (let ((two-keys (%bytes-file (merge-pathnames "two.pub" tree)
                                      (format nil "~A~%~A~%" (%shaped-key #\A) (%shaped-key #\B))))
               (key-dir (ensure-directories-exist (merge-pathnames "keys/" tree))))
           ;; Each case: (ARGV EXPECTED-PART-OF-THE-REASON . KEYS). The reason is checked, not only
           ;; that something was refused (hub's review of #568).
           (dolist (case `((("--product" "has space") "must be letters" :name "has space")
                           (("--product" "other") "differs from --name")
                           (("--product" "probe" "--product" "probe") "given more than once")
                           (("--display-name" ,(format nil "two~%lines")) "--display-name must be")
                           (("--default-channel" "Beta") "must be lowercase")
                           (("--update-source" "ftp=https://x.example/") "is not one of")
                           (("--update-source" "github=http://x.example/") "must start with https://")
                           (("--update-source" "https://x.example/") "is not KIND=URL")
                           (("--public-key-file" ,(uiop:native-namestring two-keys)) "holds 2 keys")
                           (("--public-key-file" ,(uiop:native-namestring (merge-pathnames "absent.pub" tree)))
                            "does not exist")
                           (("--public-key-file" ,(uiop:native-namestring key-dir)) "is a directory")
                           (("--release" "--update-source" "github=https://x.example/") "needs the public key")
                           (("--release") "needs at least one --update-source"
                            :env ((,ouranos-release-settings:*public-key-variable* . ,(%shaped-key #\A))))
                           (("--release" "--update-source" "github=https://x.example/") "is not a public key"
                            :env ((,ouranos-release-settings:*public-key-variable* . "not-a-key")))
                           (("--release" "--update-source" "github=https://x.example/") "is not a public key"
                            :env ((,ouranos-release-settings:*public-key-variable* . ,(subseq (%shaped-key #\A) 1))))
                           (("--product") "needs a value")))
             (destructuring-bind (argv expected &rest keys) case
               (let ((reason (apply #'%refused argv keys)))
                 (is (and reason (search expected reason))
                     "~S: expected a refusal saying ~S, got ~S" argv expected reason)))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test product-and-display-name-count-as-release-options
  ;; Each names something hyperion/update holds, so an app without it is refused when given
  ;; either (review of #568).
  (is-true (ouranos-release-settings:settings-given-p '("--product" "probe")))
  (is-true (ouranos-release-settings:settings-given-p '("--display-name" "Probe")))
  (is-false (ouranos-release-settings:settings-given-p '("--name" "probe" "--version" "1.0.0"))))

(test release-settings-are-passed-on-to-a-re-run-unchanged
  (is (equal '("--product" "probe" "--update-source" "github=https://x.example/" "--release"
               "--default-channel" "beta")
             (ouranos-release-settings:release-settings-argv
              '("--system" "probe" "--product" "probe" "--update-source" "github=https://x.example/"
                "--release" "--name" "probe" "--default-channel" "beta")))
      "the release options and their values, and nothing else"))

(test the-release-file-names-only-what-was-given
  (is (equal (format nil "product probe~%display-name Probe App~%version 1.2.3~%channel beta~%")
             (ouranos-release-settings:release-file-text
              (%release '("--product" "probe" "--display-name" "Probe App" "--default-channel" "beta"))
              "1.2.3")))
  (is (equal (format nil "version 1.2.3~%channel beta~%")
             (ouranos-release-settings:release-file-text (%release '("--default-channel" "beta")) "1.2.3"))
      "only the channel given: no product line")
  (is (null (ouranos-release-settings:release-file-text
             (%release '("--update-source" "github=https://x.example/")) "1.2.3"))
      "no product, display name or channel: no file, so it never names what the image does not have"))

;;; --- a real build -------------------------------------------------------------------------

(defun %keygen-public-key ()
  "A fresh public key from scripts/update-manifest.lisp keygen, the tool a maintainer uses."
  (let* ((out (uiop:run-program (list (uiop:native-namestring sb-ext:*runtime-pathname*) "--script"
                                      (uiop:native-namestring (merge-pathnames "update-manifest.lisp" *scripts*))
                                      "keygen")
                                :output :string :error-output nil))
         (line (find-if (lambda (l) (uiop:string-prefix-p "public" l))
                        (uiop:split-string out :separator '(#\Newline #\Return)))))
    (and line (string-trim " " (subseq line (1+ (position #\: line)))))))

(defun %build-probe (name tree app dist &rest options)
  "Run build-desktop-app.lisp on the app NAME in APP, whose entry is NAME:main, into DIST, with
OPTIONS added. Returns (values EXIT-CODE OUTPUT)."
  (let ((out (make-string-output-stream)))
    (values
     (nth-value
      2 (uiop:run-program
         (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                       "--dynamic-space-size" "4096" "--script"
                       (uiop:native-namestring (merge-pathnames "build-desktop-app.lisp" *scripts*))
                       "--system" name "--entry" (format nil "~A:main" name) "--name" name
                       "--version" "0.0.1" "--out" (uiop:native-namestring dist))
                 options)
         :directory tree :input nil :output out :error-output out :ignore-error-status t
         :environment
         ;; Ending in the separator keeps the rest of this machine's source registry, as the
         ;; gate has it: the app loads Coalton through hyperion/update, and without it the build
         ;; found an older Coalton that does not read this tree's function types.
         (cons (format nil "CL_SOURCE_REGISTRY=~A//~A~A//~A"
                       (uiop:native-namestring td-root)
                       (if (uiop:os-windows-p) ";" ":")
                       (uiop:native-namestring app)
                       (if (uiop:os-windows-p) ";" ":"))
               (remove-if (lambda (e) (or (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e)
                                          (uiop:string-prefix-p
                                           (concatenate 'string ouranos-release-settings:*public-key-variable* "=")
                                           e)))
                          (sb-ext:posix-environ)))))
     (get-output-stream-string out))))

(defun %write-updprobe (app)
  "Write the updprobe app into APP. It loads hyperion/update, sets *app-name* to \"updprobe-own\"
in its own source, as an app may, and its main prints the four settings and exits."
  (%write (merge-pathnames "updprobe.asd" app)
          "(defsystem \"updprobe\" :depends-on (\"hyperion/update\") :components ((:file \"updprobe\")))")
  (%write (merge-pathnames "updprobe.lisp" app)
          (%lines "(defpackage #:updprobe (:use #:cl) (:export #:main))"
                  "(in-package #:updprobe)"
                  "(setf hyperion/update:*app-name* \"updprobe-own\")"
                  "(defun main ()"
                  "  (format t \"~&APP-NAME ~A~%CHANNEL ~A~%KEY ~A~%\""
                  "          hyperion/update:*app-name* hyperion/update:*default-channel* hyperion/update:*public-key*)"
                  "  (finish-output)"
                  "  (let ((source hyperion/update:*update-source*))"
                  "    (format t \"~&SOURCES~{ ~A~}~%\""
                  "            (mapcar (lambda (s) (format nil \"~(~A~)~@[=~A~]\" (class-name (class-of s))"
                  "                                        (ignore-errors (hyperion/update:source-base-url s))))"
                  "                    (if (listp source) source (list source)))))"
                  "  (finish-output)"
                  "  (uiop:quit 0))")))

(defun %updprobe-bundle (dist name)
  "The bundle directory build-desktop-app.lisp made for NAME under DIST, or NIL."
  (find-if (lambda (d) (uiop:string-prefix-p (concatenate 'string name "-")
                                             (car (last (pathname-directory d)))))
           (and (uiop:directory-exists-p dist) (uiop:subdirectories dist))))

(defun %updprobe-report (bundle)
  "Run the updprobe executable in BUNDLE. Returns a function of a field name giving that field's
value, and the whole output."
  (let* ((out (uiop:run-program (list (uiop:native-namestring
                                       (merge-pathnames (if (uiop:os-windows-p) "updprobe.exe" "updprobe") bundle)))
                                :output :string :error-output :output :ignore-error-status t))
         (lines (uiop:split-string out :separator '(#\Newline #\Return))))
    (values (lambda (name)
              (let ((l (find-if (lambda (l) (uiop:string-prefix-p (format nil "~A " name) l)) lines)))
                (and l (subseq l (1+ (length name))))))
            out)))

(test a-release-build-carries-its-settings-in-the-image
  "Built with the real build-desktop-app.lisp and every release option, the running app reports
the product, the default channel, the key and the sources in order, and the bundle has a RELEASE
file. On Windows and macOS the image is dumped by a re-run of the build, so this also shows the
options reach it. CONTROL: --release without a key is refused before anything is built (#408)."
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/" tree)))
         (dist (merge-pathnames "dist/" tree))
         (key (%keygen-public-key)))
    (%write-updprobe app)
    (unwind-protect
         (progn
           (is-true key "keygen gave a public key")
           (let ((key-file (%bytes-file (merge-pathnames "updater.pub" tree) (format nil "~A~%" key))))
             ;; The control first: refused at once, with no bundle made.
             (multiple-value-bind (code out) (%build-probe "updprobe" tree app dist "--release"
                                                                  "--update-source" "github=https://example.invalid/r/")
               (is (eql 2 code) "--release without a key exits 2, got ~S:~%~A" code out)
               (is (search "needs the public key" out) "and says so:~%~A" out)
               (is (null (uiop:directory-exists-p dist)) "and builds nothing"))
             (multiple-value-bind (code out)
                 (%build-probe "updprobe" tree app dist
                                      "--product" "updprobe" "--display-name" "Update Probe"
                                      "--public-key-file" (uiop:native-namestring key-file)
                                      "--update-source" "s3=https://bucket.example.invalid/updates/updprobe"
                                      "--update-source" "github=https://example.invalid/r/releases/download/updprobe-beta/"
                                      "--default-channel" "beta" "--release")
               (is (eql 0 code) "the build failed:~%~A" out))
             (let* ((bundle (find-if (lambda (d) (uiop:string-prefix-p
                                                  "updprobe-" (car (last (pathname-directory d)))))
                                     (and (uiop:directory-exists-p dist) (uiop:subdirectories dist))))
                    (executable (and bundle (merge-pathnames (if (uiop:os-windows-p) "updprobe.exe" "updprobe")
                                                             bundle))))
               (is-true (and executable (probe-file executable)) "no executable in ~A" bundle)
               (when (and executable (probe-file executable))
                 (is (equal (format nil "product updprobe~%display-name Update Probe~%version 0.0.1~%channel beta~%")
                            (uiop:read-file-string (merge-pathnames "RELEASE" bundle)))
                     "the RELEASE file")
                 (let* ((out (uiop:run-program (list (uiop:native-namestring executable))
                                               :output :string :error-output :output :ignore-error-status t))
                        (lines (uiop:split-string out :separator '(#\Newline #\Return))))
                   (flet ((field (name)
                            (let ((l (find-if (lambda (l) (uiop:string-prefix-p (format nil "~A " name) l)) lines)))
                              (and l (subseq l (1+ (length name)))))))
                     (is (equal "updprobe" (field "APP-NAME")) "the image's *app-name*:~%~A" out)
                     (is (equal "beta" (field "CHANNEL")) "its *default-channel*:~%~A" out)
                     (is (equal key (field "KEY")) "its *public-key*:~%~A" out)
                     (is (equal "s3-source=https://bucket.example.invalid/updates/updprobe/ github-release-source=https://example.invalid/r/releases/download/updprobe-beta/"
                                (field "SOURCES"))
                         "its *update-source*, in order:~%~A" out)))))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test a-build-with-no-release-option-keeps-what-the-app-set
  "The same app, built with no release option: the running app still has the *app-name* it set in
its own source, the stable channel and no key, and the bundle has no RELEASE file (hub's review of
#568: the build used to set *app-name* from --name, replacing the app's own)."
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/" tree)))
         (dist (merge-pathnames "dist/" tree)))
    (%write-updprobe app)
    (unwind-protect
         (multiple-value-bind (code out) (%build-probe "updprobe" tree app dist)
           (is (eql 0 code) "the build failed:~%~A" out)
           (let ((bundle (%updprobe-bundle dist "updprobe")))
             (is-true bundle "no bundle in ~A" dist)
             (when bundle
               (is-false (probe-file (merge-pathnames "RELEASE" bundle))
                         "no RELEASE file, since no product, display name or channel was given")
               (multiple-value-bind (field report) (%updprobe-report bundle)
                 (is (equal "updprobe-own" (funcall field "APP-NAME"))
                     "the app's own *app-name*, not --name:~%~A" report)
                 (is (equal "stable" (funcall field "CHANNEL")) "the stable channel:~%~A" report)
                 (is (equal "NIL" (funcall field "KEY")) "no key:~%~A" report)))))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))

(test a-release-option-for-an-app-without-the-updater-leaves-no-release-file
  "An app that does not load hyperion/update, given --default-channel beta, is refused with exit
code 3, and the bundle the refused build started has no RELEASE file saying channel beta (hub's
review of #568: RELEASE was written before the refusal)."
  (let* ((tree (%fresh-tree))
         (app (ensure-directories-exist (merge-pathnames "app/" tree)))
         (dist (merge-pathnames "dist/" tree)))
    (%write (merge-pathnames "plainprobe.asd" app)
            "(defsystem \"plainprobe\" :components ((:file \"plainprobe\")))")
    (%write (merge-pathnames "plainprobe.lisp" app)
            (%lines "(defpackage #:plainprobe (:use #:cl) (:export #:main))"
                    "(in-package #:plainprobe)"
                    "(defun main () (uiop:quit 0))"))
    (unwind-protect
         (multiple-value-bind (code out) (%build-probe "plainprobe" tree app dist "--default-channel" "beta")
           (is (eql 3 code) "exit 3, got ~S:~%~A" code out)
           (is (search "does not load hyperion/update" out) "and says why:~%~A" out)
           (let ((bundle (%updprobe-bundle dist "plainprobe")))
             (is-false (and bundle (probe-file (merge-pathnames "RELEASE" bundle)))
                       "no RELEASE file in ~A" bundle)))
      (aion/fs:delete-tree tree :if-does-not-exist :ignore))))
