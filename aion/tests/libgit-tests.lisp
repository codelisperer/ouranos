;;;; libgit-tests.lisp --- aion/libgit over the libgit2 this tree builds (#429, step 2).
;;;;
;;;; GIT READS WHAT LIBGIT2 WROTE. A repository that libgit2 writes and libgit2 reads back
;;;; would pass with both halves wrong in the same way, so every test that writes checks the
;;;; result with the git command: the commit ids, parents, authors and messages git log
;;;; reports, git fsck --strict over every object, and git diff's own output compared
;;;; character for character with DIFF-TEXT's. The suite therefore needs git on PATH, which
;;;; every CI runner and every development machine here has.
;;;;
;;;; EVERY TEST GETS A NEW DIRECTORY, named with a random component under the temporary
;;;; directory, so a directory left over from an earlier run cannot be the one a test reads.

(cl:defpackage #:aion/libgit/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:git #:aion/libgit)
                    (#:fs #:aion/fs))
  (:export #:run-tests))

(in-package #:aion/libgit/tests)

(def-suite libgit :description "aion/libgit over the libgit2 this tree builds.")
(in-suite libgit)

(defun run-tests () (run! 'libgit))

;;; --- fixtures ----------------------------------------------------------------------

(defvar *random* (make-random-state t))

(defun fresh-directory ()
  (loop for dir = (uiop:ensure-directory-pathname
                   (merge-pathnames (format nil "aion-libgit-~36R" (random (expt 36 10) *random*))
                                    (uiop:temporary-directory)))
        unless (probe-file dir) return dir))

(defmacro with-directory ((var) &body body)
  `(let ((,var (fresh-directory)))
     (unwind-protect (progn ,@body)
       (fs:delete-tree ,var :if-does-not-exist :ignore))))

(defmacro with-new-repository ((repo dir) &body body)
  `(with-directory (,dir)
     (git:with-repository (,repo (git:init-repository ,dir))
       ,@body)))

(defun write-file (dir path text)
  (let ((file (merge-pathnames path dir)))
    (ensure-directories-exist file)
    (with-open-file (out file :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (write-string text out))))

(defun octets (text) (sb-ext:string-to-octets text :external-format :utf-8))

(defun git-cli (dir &rest args)
  "What the git command prints for ARGS in DIR, less one final newline."
  (let ((out (uiop:run-program (list* "git" "-C" (uiop:native-namestring dir)
                                      "-c" "core.quotepath=off" args)
                               :output :string :error-output :string
                               :external-format :utf-8)))
    (string-right-trim '(#\Newline) out)))

(defun lines (text)
  (remove "" (uiop:split-string text :separator '(#\Newline)) :test #'string=))

(defun commit-file (repo dir path text message &rest keys)
  (write-file dir path text)
  (git:stage repo (list path))
  (apply #'git:commit repo message :author "Aion Test" :email "aion@example.invalid" keys))

;;; --- the library -------------------------------------------------------------------

(defun pinned-version ()
  (with-open-file (in (merge-pathnames "libgit2.pin"
                                       (uiop:pathname-parent-directory-pathname
                                        (asdf:system-source-directory :aion))))
    (loop for line = (read-line in nil) while line
          when (uiop:string-prefix-p "version " line)
            return (string-trim " " (subseq line 8)))))

(test the-loaded-library-is-the-pinned-build
  "The library loaded is the version libgit2.pin names, from vendor/libgit2/lib/ unless
AION_LIBGIT_LIBRARY names another."
  (is (string= (pinned-version) (git:libgit2-version)))
  (let ((explicit (uiop:getenv "AION_LIBGIT_LIBRARY")))
    (if (and explicit (plusp (length explicit)))
        (is (string= explicit (git:libgit2-path)))
        (is (search "vendor/libgit2/lib/" (substitute #\/ #\\ (git:libgit2-path)))
            "loaded from ~A" (git:libgit2-path)))))

;;; --- repositories ------------------------------------------------------------------

(test init-makes-a-repository-git-recognises
  (with-new-repository (repo dir)
    (is (string= "true" (git-cli dir "rev-parse" "--is-inside-work-tree")))
    (is (equal (truename dir) (truename (git:repository-workdir repo))))
    (is (null (git:history repo)) "a new repository has no history")))

(test open-refuses-a-directory-that-is-not-a-repository
  (with-directory (dir)
    (ensure-directories-exist dir)
    (let ((e (handler-case (progn (git:open-repository dir) nil)
               (git:git-error (e) e))))
      (is (typep e 'git:git-error))
      (when e
        (is (= -3 (git:git-error-code e)))
        (is (stringp (git:git-error-message e)))))))

(test open-finds-what-init-made
  (with-directory (dir)
    (let ((id (git:with-repository (repo (git:init-repository dir))
                (commit-file repo dir "a.txt" "one" "first"))))
      (git:with-repository (repo (git:open-repository dir))
        (is (equal (list id) (mapcar #'git:commit-info-id (git:history repo))))))))

(test a-closed-repository-refuses-use-and-closes-twice
  (with-directory (dir)
    (let ((repo (git:init-repository dir)))
      (git:close-repository repo)
      (finishes (git:close-repository repo))
      (signals git:repository-closed (git:history repo))
      (signals git:repository-closed (git:stage repo '("a.txt"))))))

;;; --- commits -----------------------------------------------------------------------

(test commits-are-what-git-log-reports
  "The first commit has no parent, the second has the first, and git reports the ids,
author, email and message COMMIT was given."
  (with-new-repository (repo dir)
    (let* ((first (commit-file repo dir "a.txt" "one" "first commit"))
           (second (commit-file repo dir "a.txt" "two" "second commit")))
      (is (string= second (git-cli dir "rev-parse" "HEAD")))
      (is (string= "" (git-cli dir "log" "-1" "--format=%P" first)))
      (is (string= first (git-cli dir "log" "-1" "--format=%P" second)))
      (is (string= "Aion Test <aion@example.invalid>" (git-cli dir "log" "-1" "--format=%an <%ae>")))
      (is (string= "second commit" (git-cli dir "log" "-1" "--format=%B")))
      (is (string= "" (git-cli dir "status" "--porcelain")) "the work tree matches HEAD"))))

(test objects-pass-git-fsck-strict
  (with-new-repository (repo dir)
    (commit-file repo dir "a.txt" "one" "first")
    (commit-file repo dir "dir/b.txt" "two" "second")
    (finishes (git-cli dir "fsck" "--strict" "--no-dangling"))))

(test a-utf-8-message-and-author-reach-git-intact
  (with-new-repository (repo dir)
    (write-file dir "a.txt" "x")
    (git:stage repo '("a.txt"))
    (git:commit repo "Zürich — 東京" :author "Ångström Ñ" :email "a@example.invalid")
    (is (string= "Zürich — 東京" (git-cli dir "log" "-1" "--format=%s")))
    (is (string= "Ångström Ñ" (git-cli dir "log" "-1" "--format=%an")))
    (is (string= "Zürich — 東京" (git:commit-info-message (first (git:history repo)))))))

(test commit-records-the-time-given
  (with-new-repository (repo dir)
    (let ((time (encode-universal-time 0 30 12 1 6 2024 0)))
      (commit-file repo dir "a.txt" "one" "dated" :time time)
      (is (string= "1717245000" (git-cli dir "log" "-1" "--format=%at")))
      (is (= time (git:commit-info-time (first (git:history repo))))))))

(test staging-a-deleted-file-removes-it
  (with-new-repository (repo dir)
    (write-file dir "a.txt" "one")
    (write-file dir "b.txt" "two")
    (git:stage repo '("a.txt" "b.txt"))
    (git:commit repo "both" :author "Aion Test" :email "aion@example.invalid")
    (delete-file (merge-pathnames "a.txt" dir))
    (git:stage repo '("a.txt"))
    (git:commit repo "a gone" :author "Aion Test" :email "aion@example.invalid")
    (is (equal '("b.txt") (lines (git-cli dir "ls-tree" "-r" "--name-only" "HEAD"))))
    (is (equal '("a.txt" "b.txt") (lines (git-cli dir "ls-tree" "-r" "--name-only" "HEAD~1"))))))

;;; --- reading -----------------------------------------------------------------------

(test history-is-newest-first-and-agrees-with-git-log
  (with-new-repository (repo dir)
    (let* ((c1 (commit-file repo dir "a.txt" "one" "a one"))
           (c2 (commit-file repo dir "b.txt" "one" "b one"))
           (c3 (commit-file repo dir "a.txt" "two" "a two")))
      (is (equal (list c3 c2 c1) (mapcar #'git:commit-info-id (git:history repo))))
      (is (equal (lines (git-cli dir "log" "--format=%H"))
                 (mapcar #'git:commit-info-id (git:history repo))))
      (is (equal (list c3 c1) (mapcar #'git:commit-info-id (git:history repo :path "a.txt"))))
      (is (equal (lines (git-cli dir "log" "--format=%H" "--" "a.txt"))
                 (mapcar #'git:commit-info-id (git:history repo :path "a.txt"))))
      (is (equal (list c2) (mapcar #'git:commit-info-id (git:history repo :path "b.txt"))))
      (is (equal (list c3) (mapcar #'git:commit-info-id (git:history repo :limit 1))))
      (is (equal (list c2 c1) (mapcar #'git:commit-info-id (git:history repo :start c2))))
      (is (equal (list c2) (git:commit-info-parents (first (git:history repo))))))))

(test read-at-revision-returns-each-version
  (with-new-repository (repo dir)
    (let* ((c1 (commit-file repo dir "dir/a.txt" "one" "first"))
           (c2 (commit-file repo dir "dir/a.txt" "two, ü" "second")))
      (is (equalp (octets "one") (git:read-at-revision repo c1 "dir/a.txt")))
      (is (equalp (octets "two, ü") (git:read-at-revision repo c2 "dir/a.txt")))
      (is (equalp (octets "two, ü") (git:read-at-revision repo "HEAD" "dir/a.txt")))
      (is (equalp (octets (git-cli dir "show" (format nil "~A:dir/a.txt" c1)))
                  (git:read-at-revision repo "HEAD~1" "dir/a.txt")))
      (is (null (git:read-at-revision repo c2 "dir/missing.txt")))
      (signals git:git-error (git:read-at-revision repo "no-such-branch" "dir/a.txt"))
      (is (string= c1 (git:resolve-revision repo "HEAD~1"))))))

(test diff-text-is-what-git-diff-prints
  (with-new-repository (repo dir)
    (let* ((c1 (commit-file repo dir "a.txt" (format nil "one~%two~%three~%") "first"))
           (c2 (progn (write-file dir "b.txt" (format nil "new~%"))
                      (git:stage repo '("b.txt"))
                      (commit-file repo dir "a.txt" (format nil "one~%2~%three~%") "second"))))
      (let ((ours (git:diff-text repo c1 c2)))
        (is (search (format nil "-two~%+2~%") ours))
        (is (string= (format nil "~A~%" (git-cli dir "diff" "--no-color" c1 c2)) ours)))
      (is (string= (format nil "~A~%" (git-cli dir "diff" "--no-color"
                                               "4b825dc642cb6eb9a060e54bf8d69288fbee4904" c1))
                   (git:diff-text repo nil c1))
          "from NIL is from the empty tree")
      (is (string= "" (git:diff-text repo c2 c2))))))

;;; --- threads -----------------------------------------------------------------------

(test four-threads-each-with-a-repository-commit-at-once
  "libgit2 is built with threads on, and each repository object is used by one thread. Four
threads commit twenty times each into four repositories at once; every history has all
twenty and passes git fsck."
  (let ((dirs (loop repeat 4 collect (fresh-directory))))
    (unwind-protect
         (let ((threads
                 (loop for dir in dirs
                       collect (let ((dir dir))
                                 (sb-thread:make-thread
                                  ;; An error is returned rather than left unhandled,
                                  ;; which would end the whole test process.
                                  (lambda ()
                                    (handler-case
                                        (git:with-repository (repo (git:init-repository dir))
                                          (dotimes (i 20)
                                            (commit-file repo dir "a.txt" (format nil "~D" i)
                                                         (format nil "commit ~D" i)))
                                          (length (git:history repo)))
                                      (error (e) (princ-to-string e))))
                                  :name "aion/libgit test")))))
           (is (equal '(20 20 20 20)
                      (mapcar (lambda (th) (sb-thread:join-thread th :timeout 120 :default :timeout))
                              threads)))
           (dolist (dir dirs)
             (is (string= "20" (git-cli dir "rev-list" "--count" "HEAD")))
             (finishes (git-cli dir "fsck" "--strict" "--no-dangling"))))
      (dolist (dir dirs) (fs:delete-tree dir :if-does-not-exist :ignore)))))

;;; --- review of #470 on train 19 (#479) -------------------------------------------------

(test the-functions-bound-are-the-functions-the-build-requires
  "build-libgit2.lisp refuses a library that does not export a function in *REQUIRED-SYMBOLS*,
and the load refuses one whose bound functions resolve elsewhere. Both lists must be the
functions ffi.lisp binds."
  (let* ((text (uiop:read-file-string
                (merge-pathnames "scripts/build-libgit2.lisp"
                                 (uiop:pathname-parent-directory-pathname
                                  (asdf:system-source-directory :aion)))))
         (start (search "(defparameter *required-symbols*" text))
         (end (search "\"Every entry point" text :start2 start))
         (required (let ((names '()) (i start))
                     (loop for q = (position #\" text :start i :end end)
                           while q
                           do (let ((close (position #\" text :start (1+ q))))
                                (push (subseq text (1+ q) close) names)
                                (setf i (1+ close))))
                     names)))
    (is (= 53 (length git::*entry-points*)))
    (is (null (set-exclusive-or required git::*entry-points* :test #'string=))
        "differ: ~S" (set-exclusive-or required git::*entry-points* :test #'string=))))

(test a-build-with-experimental-sha256-is-refused
  "That build's git_oid is 33 bytes and this binding allocates 20. CONTROL: the same version
and threads without the SHA-256 bit is accepted, and the loaded library does not have it."
  (is (search "SHA-256" (or (git::%build-mismatch '(1 9 7) (logior 1 2048)) "")))
  (is (null (git::%build-mismatch '(1 9 7) 1)))
  (git:ensure-loaded)
  (is (zerop (logand (git::%features) 2048))))

(defun %child-load-report (&key preload)
  "Load aion/libgit in a child image and print what LOAD-LIBGIT2 did. With PRELOAD, the child
first loads that file as a foreign library, as another part of an app could."
  (let ((out (make-string-output-stream)))
    (uiop:run-program
     (list (uiop:native-namestring sb-ext:*runtime-pathname*)
           "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
           "--eval" "(require :asdf)"
           "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
           "--eval" "(asdf:load-system :aion/libgit)"
           "--eval" (if preload
                        (format nil "(cffi:load-foreign-library ~S)" (uiop:native-namestring preload))
                        "t")
           "--eval" "(handler-case (format t \"~&LOADED ~A~%\" (aion/libgit:load-libgit2)) (aion/libgit:libgit2-mismatch (e) (format t \"~&MISMATCH ~A~%\" (aion/libgit:libgit2-mismatch-reason e))))")
     :output out :error-output out :ignore-error-status t)
    (get-output-stream-string out)))

(test another-libgit2-loaded-first-is-refused
  "On SBCL a foreign call resolves across the process, so a libgit2 another part of the app
loaded first would receive every call while LIBGIT2-PATH named ours. A copy of our own
library under another name stands in for it, so its version and features pass every other
check. CONTROL: without the copy loaded first, the load succeeds."
  (let ((copy (merge-pathnames (format nil "other-~A" (file-namestring (git:libgit2-path)))
                               (fresh-directory))))
    (ensure-directories-exist copy)
    (unwind-protect
         (progn
           (uiop:copy-file (git:libgit2-path) copy)
           (let ((refused (%child-load-report :preload copy)))
             (is (search "MISMATCH" refused) "~A" refused)
             (is (search "resolves to another library" refused) "~A" refused))
           (let ((plain (%child-load-report)))
             (is (search "LOADED" plain) "~A" plain)))
      (fs:delete-tree (uiop:pathname-directory-pathname copy) :if-does-not-exist :ignore))))

#-win32
(test history-of-a-path-includes-a-change-of-mode-alone
  "chmod +x changes no bytes and is a change git log -- PATH lists."
  (with-new-repository (repo dir)
    (let* ((c1 (commit-file repo dir "run.sh" (format nil "echo hi~%") "add"))
           (file (merge-pathnames "run.sh" dir)))
      (sb-posix:chmod (uiop:native-namestring file) #o755)
      (git:stage repo '("run.sh"))
      (let ((c2 (git:commit repo "make it executable" :author "Aion Test" :email "aion@example.invalid")))
        (is (equal (list c2 c1) (mapcar #'git:commit-info-id (git:history repo :path "run.sh"))))
        (is (equal (lines (git-cli dir "log" "--format=%H" "--" "run.sh"))
                   (mapcar #'git:commit-info-id (git:history repo :path "run.sh"))))))))

(defun git-commit-cli (dir message)
  (git-cli dir "-c" "user.name=Aion Test" "-c" "user.email=aion@example.invalid"
           "commit" "-q" "-m" message))

(test history-of-a-path-leaves-out-a-branch-a-merge-discarded
  "A side branch changes a.txt, and the merge keeps the main line's a.txt (git merge -s ours).
git log -- a.txt does not list the side commit, because the merge is TREESAME to its first
parent and the walk follows that parent only. CONTROL: a merge that takes the side's a.txt
lists it."
  (dolist (strategy '("ours" "theirs"))
    (with-new-repository (repo dir)
      (commit-file repo dir "a.txt" (format nil "one~%") "base")
      (let ((main (git-cli dir "symbolic-ref" "--short" "HEAD")))
        (git-cli dir "checkout" "-q" "-b" "side")
        (let ((side (commit-file repo dir "a.txt" (format nil "side~%") "side change")))
          (git-cli dir "checkout" "-q" main)
          (commit-file repo dir "b.txt" (format nil "b~%") "main change")
          (if (string= strategy "ours")
              (git-cli dir "-c" "user.name=Aion Test" "-c" "user.email=aion@example.invalid"
                       "merge" "-q" "-s" "ours" "-m" "merge" "side")
              (progn
                (git-cli dir "-c" "user.name=Aion Test" "-c" "user.email=aion@example.invalid"
                         "merge" "-q" "--no-commit" "-s" "ours" "side")
                (git-cli dir "checkout" "side" "--" "a.txt")
                (git-commit-cli dir "merge")))
          (let ((ours (mapcar #'git:commit-info-id (git:history repo :path "a.txt"))))
            (is (equal (lines (git-cli dir "log" "--format=%H" "--" "a.txt")) ours)
                "~A: git and aion/libgit disagree" strategy)
            (if (string= strategy "ours")
                (is (not (member side ours :test #'string=)) "the discarded side commit is listed")
                (is (member side ours :test #'string=) "the kept side commit is missing"))))))))

(test diff-text-shows-a-rename-as-git-diff-does
  "git diff detects renames by default, and git_diff_tree_to_tree alone does not."
  (with-new-repository (repo dir)
    (let* ((c1 (commit-file repo dir "old.txt" (format nil "one~%two~%three~%") "add"))
           (c2 (progn (rename-file (merge-pathnames "old.txt" dir) (merge-pathnames "new.txt" dir))
                      (git:stage repo '("old.txt" "new.txt"))
                      (git:commit repo "rename" :author "Aion Test" :email "aion@example.invalid")))
           (ours (git:diff-text repo c1 c2)))
      (is (search "rename from old.txt" ours) "~A" ours)
      (is (string= (format nil "~A~%" (git-cli dir "-c" "diff.renames=true" "diff" "--no-color" c1 c2))
                   ours)))))

(test commit-includes-what-another-process-staged
  "git add run by another process after this repository last read its index: COMMIT must see
it. libgit2 keeps the index in memory, so without re-reading it, the commit would be made
from the copy that predates the git add."
  (with-new-repository (repo dir)
    (commit-file repo dir "a.txt" (format nil "a~%") "first")
    (write-file dir "b.txt" (format nil "b~%"))
    (git-cli dir "add" "b.txt")
    (git:commit repo "b, staged by git" :author "Aion Test" :email "aion@example.invalid")
    (is (equal '("a.txt" "b.txt") (lines (git-cli dir "ls-tree" "-r" "--name-only" "HEAD"))))))

;;; --- a desktop bundle does not search the source tree (#429 step 3, #472) -------------

(defun %vendored-libgit-candidates (candidates)
  "The entries of CANDIDATES in the source tree's vendor/libgit2."
  (remove-if-not (lambda (c) (search "vendor/libgit2/lib/" (substitute #\/ #\\ c))) candidates))

(test a-bundle-does-not-search-the-source-tree-for-libgit2
  "A desktop app's image has AION/PLATFORM:*SEARCH-SOURCE-TREE* NIL, so libgit2's search leaves
out vendor/libgit2, which exists only where the app was built."
  (let ((tree (let ((aion/platform:*search-source-tree* t))
                (%vendored-libgit-candidates (git::%candidates)))))
    (if (null tree)
        (skip "aion's source directory is unknown here, so there is no vendored path to leave out")
        (progn
          (is-true tree "control: by default the source tree is searched")
          (let ((aion/platform:*search-source-tree* nil))
            (is (null (%vendored-libgit-candidates (git::%candidates)))
                "in a bundle it is not: ~S" (git::%candidates)))))))

(defun %libgit2-loaded-in-a-fresh-image (search-source-tree)
  "Start a fresh image that loads aion/libgit, sets AION/PLATFORM:*SEARCH-SOURCE-TREE* to
SEARCH-SOURCE-TREE, and loads libgit2 with AION_LIBGIT_LIBRARY empty. Returns the path it
loaded, or :FAILED. A fresh image, because this one already has libgit2 loaded."
  (let ((out (uiop:run-program
              (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                    "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
                    "--eval" "(require :asdf)"
                    "--eval" (format nil "(load ~S)"
                                     (uiop:native-namestring
                                      (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
                    "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :aion/libgit))"
                    "--eval" "(setf (uiop:getenv \"AION_LIBGIT_LIBRARY\") \"\")"
                    "--eval" (format nil "(setf aion/platform:*search-source-tree* ~:[nil~;t~])"
                                     search-source-tree)
                    "--eval" "(format t \"~&LOADED ~A~%\" (handler-case (aion/libgit:load-libgit2) (error () :failed)))")
              :input nil :output :string :error-output nil :ignore-error-status t)))
    (let ((line (find-if (lambda (l) (uiop:string-prefix-p "LOADED " l))
                         (uiop:split-string out :separator '(#\Newline #\Return)))))
      (if (null line)
          (list :no-answer out)
          (let ((value (subseq line 7)))
            (if (string-equal value "FAILED") :failed value))))))

(test a-bundle-without-its-libgit2-does-not-load-the-source-trees
  "With no copy beside the image and a vendor/libgit2 copy present, a bundle's image fails to
load libgit2, or loads one that is not the tree's. CONTROL: any other image loads the tree's."
  (let ((tree (remove-if-not #'probe-file
                             (let ((aion/platform:*search-source-tree* t))
                               (%vendored-libgit-candidates (git::%candidates))))))
    (if (null tree)
        (skip "no built libgit2 in vendor/ here, so nothing to leave out")
        (let ((bundle (%libgit2-loaded-in-a-fresh-image nil))
              (other (%libgit2-loaded-in-a-fresh-image t)))
          (flet ((from-tree-p (path)
                   (and (stringp path)
                        (search "vendor/libgit2/lib/" (substitute #\/ #\\ path)))))
            (is (and (not (consp bundle)) (not (from-tree-p bundle)))
                "a bundle's image must not load the source tree's libgit2: ~S" bundle)
            (is (from-tree-p other)
                "control: any other image loads the vendored copy: ~S" other))))))
