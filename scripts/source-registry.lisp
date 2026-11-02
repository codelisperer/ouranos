;;;; source-registry.lisp --- which tree bootstrap.lisp points this machine's ASDF at (#955)
;;;;
;;;; bootstrap.lisp writes one ASDF source-registry drop-in, 50-ouranos.conf, under the user's
;;;; configuration directory. Every REPL, editor and build that runs as this user and does not
;;;; set CL_SOURCE_REGISTRY finds the frameworks through it. Before #955, bootstrap rewrote it
;;;; on every run, so running bootstrap in a second checkout (a lane's worktree, or a scratch
;;;; clone pinned to an older commit) silently moved every other process on the machine to
;;;; that checkout's frameworks.
;;;;
;;;; Now bootstrap decides what to do from what the drop-in names:
;;;;
;;;;   - no drop-in                                         -> write it (:write);
;;;;   - the drop-in names this tree, or a tree that is gone -> rewrite it (:rewrite);
;;;;   - it names another tree that exists, or cannot be read as one (:tree "...") form
;;;;       -> refuse (:refuse), or with OURANOS_BOOTSTRAP_FORCE=1 rewrite it (:repoint);
;;;;   - OURANOS_BOOTSTRAP_LOCAL=1 -> leave the drop-in alone, unread, and point this process
;;;;       and its children at this tree through CL_SOURCE_REGISTRY instead (:local).
;;;;
;;;; REGISTRY-ACTION is the decision and does no IO. CLASSIFY-DROP-IN reads the file and the
;;;; file system, and REGISTRY-STEP does the whole step for bootstrap.lisp. Loaded by path from
;;;; bootstrap.lisp, and from the checkers suite, which tests it against a temporary
;;;; configuration directory.

(defpackage #:ouranos-registry
  (:use #:cl)
  (:export #:drop-in-path #:classify-drop-in #:registry-action #:registry-step
           #:local-registry-value #:refusal-commands #:same-tree-p
           #:registry-refused #:registry-refused-drop-in #:registry-refused-this-tree
           #:registry-refused-other-tree))

(in-package #:ouranos-registry)

(defun drop-in-path ()
  "The drop-in bootstrap writes. `xdg-config-home' reads XDG_CONFIG_HOME when it is set, and
otherwise gives the directory ASDF reads on this OS (~/.config on Linux and macOS,
%LOCALAPPDATA%\\config on Windows), so ASDF and bootstrap agree on the file."
  (uiop:xdg-config-home "common-lisp" "source-registry.conf.d" "50-ouranos.conf"))

(defun %tree-string (root)
  "ROOT as the drop-in records it: forward slashes, so the Lisp reader accepts it on Windows,
where a backslash would be read as an escape character."
  (substitute #\/ #\\ (namestring root)))

(defun %named-tree (conf)
  "The string inside CONF's single (:tree \"...\") form, or NIL when CONF holds anything else.
Read with *READ-EVAL* off, because the file may have been edited by hand."
  (handler-case
      (with-open-file (in conf :external-format :utf-8)
        (let* ((*read-eval* nil)
               (form (read in nil in))
               (more (read in nil in)))
          (and (consp form)
               (eq (first form) :tree)
               (stringp (second form))
               (null (cddr form))
               (eq more in)
               (second form))))
    (error () nil)))

(defun %shown (string)
  "STRING, a path as the drop-in records it, in this OS's own spelling for a message (#168)."
  (uiop:native-namestring (uiop:parse-native-namestring string)))

(defun %existing-directory (string)
  "The truename of the directory STRING names, or NIL when there is none."
  (ignore-errors
   (probe-file (uiop:ensure-directory-pathname (uiop:parse-native-namestring string)))))

(defun same-tree-p (a b &key (windows (uiop:os-windows-p)))
  "Whether A and B, two directory namestrings, name the same tree. Both are compared with
forward slashes. On Windows the comparison ignores case, because the file system does, and
an older drop-in can spell the drive c: where *LOAD-TRUENAME* spells it C:; without this, the
refusal would name the same tree twice."
  (funcall (if windows #'string-equal #'string=)
           (substitute #\/ #\\ a) (substitute #\/ #\\ b)))

(defun classify-drop-in (conf this-tree)
  "What CONF says about THIS-TREE. Returns (values KIND OTHER), where OTHER is the tree named in
CONF, as written there, and KIND is one of:

  :NONE        CONF does not exist;
  :SAME        CONF names THIS-TREE, compared by truename, so a path through a symbolic link to
               this tree counts as this tree;
  :MISSING     CONF names a directory that no longer exists;
  :OTHER       CONF names another directory that exists;
  :UNREADABLE  CONF is not a single (:tree \"...\") form."
  (cond
    ((not (probe-file conf)) (values :none nil))
    (t
     (let ((other (%named-tree conf)))
       (if (null other)
           (values :unreadable nil)
           (let ((found (%existing-directory other)))
             (values (cond ((null found) :missing)
                           ((same-tree-p (namestring found) (namestring (truename this-tree)))
                            :same)
                           (t :other))
                     other)))))))

(defun registry-action (kind &key local force)
  "What bootstrap does about the drop-in, given KIND from CLASSIFY-DROP-IN. No IO.

  :LOCAL    LOCAL is set: the drop-in is not read or written, whatever KIND is;
  :WRITE    there is no drop-in;
  :REWRITE  the drop-in names this tree, or a tree that no longer exists;
  :REPOINT  the drop-in names another tree, or cannot be read, and FORCE is set;
  :REFUSE   the drop-in names another tree, or cannot be read, and FORCE is not set."
  (cond (local :local)
        (t (ecase kind
             (:none :write)
             ((:same :missing) :rewrite)
             ((:other :unreadable) (if force :repoint :refuse))))))

(defun local-registry-value (root &key (windows (uiop:os-windows-p)))
  "The CL_SOURCE_REGISTRY value that makes ASDF search ROOT as a tree and then read the rest of
the configuration: ROOT, then //, then the separator, which is ; on Windows and : elsewhere."
  (concatenate 'string
               (string-right-trim "/\\" (uiop:native-namestring root))
               "//" (if windows ";" ":")))

(defun %single-quoted (string windows)
  "STRING inside single quotes for this OS's shell. A quote inside it is written '' for
PowerShell and '\\'' for a POSIX shell, so a path containing one still pastes as one word."
  (with-output-to-string (out)
    (write-char #\' out)
    (loop for char across string
          do (if (char= char #\')
                 (write-string (if windows "''" "'\\''") out)
                 (write-char char out)))
    (write-char #\' out)))

(defun refusal-commands (root &key (windows (uiop:os-windows-p)))
  "The lines a refusal prints under its explanation: the command for each way forward, written
for this OS's shell (PowerShell on Windows, a POSIX shell elsewhere)."
  (let ((bootstrap "sbcl --dynamic-space-size 4096 --script bootstrap.lisp")
        (value (local-registry-value root :windows windows)))
    (if windows
        (list "To build this tree and leave the drop-in alone, run this in PowerShell, from this tree:"
              (concatenate 'string "  $env:OURANOS_BOOTSTRAP_LOCAL='1'; " bootstrap "; Remove-Item Env:OURANOS_BOOTSTRAP_LOCAL")
              "and, in each PowerShell session that should use this tree:"
              (concatenate 'string "  $env:CL_SOURCE_REGISTRY=" (%single-quoted value t))
              "To make this tree the one every process on this machine uses, run this from this tree:"
              (concatenate 'string "  $env:OURANOS_BOOTSTRAP_FORCE='1'; " bootstrap "; Remove-Item Env:OURANOS_BOOTSTRAP_FORCE"))
        (list "To build this tree and leave the drop-in alone, run this from this tree:"
              (concatenate 'string "  OURANOS_BOOTSTRAP_LOCAL=1 " bootstrap)
              "and, in each shell that should use this tree:"
              (concatenate 'string "  export CL_SOURCE_REGISTRY=" (%single-quoted value nil))
              "To make this tree the one every process on this machine uses, run this from this tree:"
              (concatenate 'string "  OURANOS_BOOTSTRAP_FORCE=1 " bootstrap)))))

(define-condition registry-refused (error)
  ((drop-in :initarg :drop-in :reader registry-refused-drop-in)
   (this-tree :initarg :this-tree :reader registry-refused-this-tree)
   (other-tree :initarg :other-tree :reader registry-refused-other-tree
               :documentation "The tree the drop-in names, or NIL when it could not be read."))
  (:report
   (lambda (c stream)
     (let ((conf (uiop:native-namestring (registry-refused-drop-in c)))
           (this (uiop:native-namestring (registry-refused-this-tree c)))
           (other (registry-refused-other-tree c)))
       (format stream "bootstrap: stopped before building anything.~%")
       (if other
           (format stream "The ASDF drop-in ~A~%names the tree ~A~%and this bootstrap was run from ~A.~%Rewriting it would make every REPL, editor and build on this machine that reads it load the frameworks from this tree instead.~%"
                   conf (%shown other) this)
           (format stream "The ASDF drop-in ~A~%is not a single (:tree \"...\") form, so bootstrap cannot tell which tree it names. This bootstrap was run from ~A.~%Rewriting it would replace whatever the file says now.~%"
                   conf this))
       (dolist (line (refusal-commands (registry-refused-this-tree c)))
         (format stream "~A~%" line))))))

(defun registry-step (root &key (conf (drop-in-path))
                                (getenv #'uiop:getenv)
                                (stream *standard-output*))
  "Do bootstrap's drop-in step for the tree at ROOT, and return the action taken (see
REGISTRY-ACTION). GETENV reads OURANOS_BOOTSTRAP_LOCAL and OURANOS_BOOTSTRAP_FORCE; a test
passes its own. Each switch is on only when its value is exactly \"1\", as the docs say, so
OURANOS_BOOTSTRAP_LOCAL=0 leaves local mode off. Signals REGISTRY-REFUSED, and leaves CONF exactly as it was, on :REFUSE.

On :LOCAL this sets CL_SOURCE_REGISTRY in this process's environment, so the child sbcl
processes bootstrap starts afterwards (the warm step and the platform package) build against
ROOT and not against the tree the drop-in names."
  (let ((local (equal "1" (funcall getenv "OURANOS_BOOTSTRAP_LOCAL")))
        (force (equal "1" (funcall getenv "OURANOS_BOOTSTRAP_FORCE"))))
    (multiple-value-bind (kind other)
        (if local (values nil nil) (classify-drop-in conf root))
      (let ((action (registry-action kind :local local :force force)))
        (ecase action
          (:local
           (let ((value (local-registry-value root)))
             (setf (uiop:getenv "CL_SOURCE_REGISTRY") value)
             (format stream "~&bootstrap: tree-local (OURANOS_BOOTSTRAP_LOCAL); the drop-in was not read or changed.~%bootstrap: this run and its child processes use CL_SOURCE_REGISTRY=~A~%"
                     value)))
          (:refuse
           (error 'registry-refused :drop-in conf :this-tree root :other-tree other))
          ((:write :rewrite :repoint)
           (ensure-directories-exist conf)
           (with-open-file (out conf :direction :output :external-format :utf-8
                                     :if-exists :supersede :if-does-not-exist :create)
             ;; A conf.d file holds a single directive, with no :source-registry wrapper and no
             ;; :inherit-configuration; both are implied.
             (format out ";;;; Generated by ouranos/bootstrap.lisp -- machine-local, do not commit.~%(:tree \"~A\")~%"
                     (%tree-string root)))
           (when (eq kind :missing)
             (format stream "~&bootstrap: the drop-in named ~A, which no longer exists; it now names this tree.~%"
                     (%shown other)))
           (when (eq action :repoint)
             (format stream "~&bootstrap: OURANOS_BOOTSTRAP_FORCE is set; the drop-in named ~A and now names this tree.~%"
                     (if other (%shown other) "something bootstrap could not read")))
           (format stream "~&bootstrap: source-registry -> ~A~%" (uiop:native-namestring conf))))
        action))))
