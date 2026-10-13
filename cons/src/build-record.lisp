;;;; build-record.lisp --- is bin/cons older than the source it was built from? (#526)
;;;;
;;;; bin/cons is a dumped image, built by bootstrap.lisp and not by `git pull'. After a pull the
;;;; clone has new code and the binary still runs the old, and nothing said so: a clone pulled
;;;; forward kept answering "no target --strict" because its binary predated the option.
;;;;
;;;; RECORD-BUILD runs in bootstrap.lisp just before the dump. It keeps the commit the tree was
;;;; at, the time, every source file of the systems in the image that lie in the tree, taken
;;;; from ASDF, so the list follows cons's dependencies without being kept by hand, and the files
;;;; bootstrap.lisp loads without ASDF, read from bootstrap.lisp itself. CHECK runs at
;;;; startup in CONS/CLI:MAIN, beside CONS/TOOLCHAIN:CHECK, and prints one line on stderr when a
;;;; recorded file has a later write date than the build or has gone. Write dates and not commits,
;;;; because a pull rewrites the files it changes and so does an edit that was never committed,
;;;; and comparing dates needs no git process on every start. git is run only to name the commit
;;;; in that line. CHANGED-FILES is pure over the dates it is given, so its cases are testable
;;;; without a binary.

(in-package #:cons/build-record)

(defvar *record* nil
  "What RECORD-BUILD kept in this image: a plist of :COMMIT (a string, or NIL without git), :TIME
(a universal time) and :FILES (paths relative to the tree root, as strings with forward
slashes). NIL in an image bootstrap.lisp did not dump.")

(defun %git-head (root)
  "The commit ROOT's checkout is at, or NIL when git cannot say."
  (let ((out (ignore-errors
              (uiop:run-program (list "git" "-C" (uiop:native-namestring root) "rev-parse" "HEAD")
                                :output :string :error-output nil :ignore-error-status t))))
    (let ((sha (and out (string-trim '(#\Space #\Return #\Newline) out))))
      (and sha (= (length sha) 40) sha))))

(defun %relative (path root)
  "PATH as a string relative to ROOT with forward slashes, or NIL when it is not under ROOT."
  (let ((p (namestring path))
        (r (namestring root)))
    (when (and (>= (length p) (length r))
               (if (uiop:os-windows-p)
                   (string-equal r p :end2 (length r))
                   (string= r p :end2 (length r))))
      (substitute #\/ #\\ (subseq p (length r))))))

(defun %source-files (system)
  "SYSTEM's .asd and every Lisp source file among its components."
  (let ((files (list (asdf:system-source-file system))))
    (labels ((walk (component)
               (typecase component
                 (asdf:cl-source-file (push (asdf:component-pathname component) files))
                 (asdf:parent-component (mapc #'walk (asdf:component-children component))))))
      (walk system))
    (remove nil files)))

(defun image-files (root)
  "The source files, relative to ROOT, of every system loaded in this image whose files lie
under ROOT."
  (let ((root (uiop:ensure-directory-pathname (truename root)))
        (files '()))
    (dolist (name (asdf:already-loaded-systems))
      (let ((system (ignore-errors (asdf:find-system name nil))))
        (when system
          (dolist (file (%source-files system))
            (let ((relative (%relative (or (ignore-errors (truename file)) file) root)))
              (when relative (pushnew relative files :test #'string=)))))))
    (sort files #'string<)))

(defun bootstrap-inputs (root)
  "The files bootstrap.lisp builds bin/cons from without ASDF: bootstrap.lisp itself, which
decides the contribs and the heap baked into the image, and every scripts/*.lisp it names that
exists, such as dump-image.lisp, which defines what the binary does when it starts. Read from
bootstrap.lisp, so a script it starts to load is recorded without a list kept by hand (Copilot's
review of #660)."
  (let ((text (ignore-errors (uiop:read-file-string (merge-pathnames "bootstrap.lisp" root))))
        (files '()))
    (when text
      (push "bootstrap.lisp" files)
      (loop with start = 0
            for at = (search "\"scripts/" text :start2 start)
            while at
            do (let ((end (position #\" text :start (1+ at))))
                 (when end
                   (let ((name (subseq text (1+ at) end)))
                     (when (and (uiop:string-suffix-p name ".lisp")
                                (probe-file (merge-pathnames name root)))
                       (pushnew name files :test #'string=))))
                 (setf start (1+ at)))))
    (sort files #'string<)))

(defun record-build (root)
  "Keep, in this image, what CHECK compares against: ROOT's commit, the time, and the files
IMAGE-FILES and BOOTSTRAP-INPUTS name. Called by bootstrap.lisp just before it dumps bin/cons.
Returns the record."
  (setf *record* (list :commit (%git-head root)
                       :time (get-universal-time)
                       :files (sort (union (image-files root) (bootstrap-inputs root)
                                           :test #'string=)
                                    #'string<))))

(defun changed-files (record dates)
  "The recorded files that changed after the build. DATES maps each of RECORD's files to its
write date now, or NIL when it is gone; it is a function of the relative path. Returns (values
CHANGED MISSING), each a list of relative paths."
  (let ((changed '()) (missing '()))
    (dolist (file (getf record :files))
      (let ((date (funcall dates file)))
        (cond ((null date) (push file missing))
              ((> date (getf record :time)) (push file changed)))))
    (values (nreverse changed) (nreverse missing))))

(defun binary-root (&optional (runtime sb-ext:*runtime-pathname*))
  "The tree this binary was built into, when RUNTIME is <root>/bin/cons(.exe) in a directory
that holds bootstrap.lisp; otherwise NIL, and there is nothing to compare."
  (let* ((dir (uiop:pathname-directory-pathname runtime))
         (root (uiop:pathname-parent-directory-pathname dir)))
    (and (equal "bin" (car (last (pathname-directory dir))))
         (probe-file (merge-pathnames "bootstrap.lisp" root))
         root)))

(defun %date-under (root)
  (lambda (relative) (ignore-errors (file-write-date (merge-pathnames relative root)))))

(defun %format-time (time)
  (multiple-value-bind (s mi h d mo y) (decode-universal-time time 0)
    (format nil "~D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D UTC" y mo d h mi s)))

(defun report (record root changed missing &key (stream *error-output*))
  "Print the one line CHECK prints when bin/cons is older than its source."
  (let ((now (%git-head root)))
    (format stream "cons: bin/cons was built~@[ from ~A~] at ~A, and ~A~@[ (and ~D more)~] since~@[; the clone is at ~A~].~%cons: rebuild only bin/cons, leaving the ASDF drop-in alone: sbcl --dynamic-space-size 4096 --script bootstrap.lisp --cons-only~%"
            (let ((c (getf record :commit))) (and c (subseq c 0 (min 12 (length c)))))
            (%format-time (getf record :time))
            (if changed
                (format nil "~A has changed" (first changed))
                (format nil "~A has been removed" (first missing)))
            (let ((more (1- (+ (length changed) (length missing))))) (and (plusp more) more))
            (and now (not (equal now (getf record :commit))) (subseq now 0 12)))))

(defun check (&key (record *record*) (root (binary-root)) (stream *error-output*))
  "Warn on STREAM when a source file of this binary changed after it was built. Never fatal.
Returns (values CHANGED MISSING), or NIL when there is no record or no tree to compare."
  (when (and record root)
    (multiple-value-bind (changed missing) (changed-files record (%date-under root))
      (when (or changed missing)
        (report record root changed missing :stream stream))
      (values changed missing))))

(defun describe-build (&key (record *record*))
  "One line for `cons version': the commit and time this binary was built from, or NIL."
  (when record
    (format nil "built~@[ from ~A~] at ~A"
            (getf record :commit) (%format-time (getf record :time)))))
