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
