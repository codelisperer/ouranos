;;;; project.lisp --- locate the project root + point ASDF at it, at runtime.
;;;;
;;;; The keystone under everything `cons` will do to a source tree (build / test /
;;;; serve / run). Two problems it solves, both consequences of `cons` shipping as a
;;;; dumped image (`bin/cons`):
;;;;
;;;;   1. The path is BAKED IN. `bootstrap.lisp` initializes ASDF's source registry
;;;;      to the tree it saw at dump time; that absolute path rides inside the image
;;;;      and goes stale the moment the repo moves or the binary lands on another
;;;;      machine. So `cons` must recompute the root at RUNTIME and re-point ASDF.
;;;;   2. `cons` is GENERIC. It must work on whatever project it is invoked in
;;;;      (ouranos, a consuming app, a freshly-scaffolded app), not just the one it was
;;;;      born in -- so "the root" is "walk up from where I was run", not a constant.
;;;;
;;;; FIND-ROOT walks upward to a marker; ENSURE-SOURCE-REGISTRY re-initializes ASDF
;;;; with `(:tree <root>) :inherit-configuration`, so the current checkout supplies
;;;; the project's own systems while the standing drop-in (50-ouranos.conf) and
;;;; Quicklisp still supply external deps. Format-agnostic on purpose: the build spec
;;;; that will DRIVE build/test/serve/run layers on top of this, and can refine how
;;;; the root is marked without changing callers. uiop-only (cons stays
;;;; dependency-light -- it is a bootstrapping tool).

(in-package #:cons/project)

(defparameter *root-markers* '(".git")
  "Filesystem entries whose presence in a directory marks it as a project root, tried
in order. Today just `.git` (a directory in a normal checkout, a file in a git
worktree -- PROBE-FILE matches either). A future `cons` manifest file will join this
list without changing any caller.")

(defun %marker-present-p (dir)
  "True when DIR (a directory pathname) directly contains a *ROOT-MARKERS* entry."
  (some (lambda (m) (probe-file (merge-pathnames m dir))) *root-markers*))

(defun find-root (&optional (start (uiop:getcwd)))
  "Walk upward from START (a directory pathname; default the current directory) to the
nearest ancestor holding a project-root marker (see *ROOT-MARKERS*), and return that
directory pathname -- or NIL if the filesystem root is reached with no marker. This is
what lets `cons` resolve systems from the CURRENT checkout at runtime, rather than the
path baked into `bin/cons` at bootstrap."
  (labels ((up (dir)
             (cond ((%marker-present-p dir) dir)
                   (t (let ((parent (uiop:pathname-parent-directory-pathname dir)))
                        (if (equal (namestring parent) (namestring dir)) ; hit fs root
                            nil
                            (up parent)))))))
    (up (uiop:ensure-directory-pathname (truename start)))))

(defun project-root (&optional (start (uiop:getcwd)))
  "The project root for START (default the current directory): FIND-ROOT, or START
itself when no marker is found -- a best-effort fallback so callers always get a
usable directory pathname."
  (or (find-root start)
      (uiop:ensure-directory-pathname (truename start))))

(defun ensure-source-registry (&optional (root (project-root)))
  "(Re)initialize ASDF's source registry so this project's systems resolve from ROOT's
tree at RUNTIME -- overriding whatever path was baked into `bin/cons` when the image
was dumped. Uses `(:tree ROOT)` plus `:inherit-configuration`, so the standing
source-registry drop-in (50-ouranos.conf) and Quicklisp still supply external deps.
Idempotent; returns ROOT."
  (let ((root (uiop:ensure-directory-pathname root)))
    (asdf:initialize-source-registry
     `(:source-registry (:tree ,root) :inherit-configuration))
    root))

(defun system-name (&optional (root (project-root)))
  "The project's system name: the stem of the `.asd` in ROOT matching the directory name if
present, else the first `.asd`, else the directory name. NIL when there is no ROOT.

Lives here rather than in cons/setup because more than one subcommand needs to answer which
project it is standing in -- `cons setup` names its drop-in from it, `cons env` needs a
system to scan the dependencies of -- and two implementations of that question would
eventually disagree."
  (when root
    (let* ((asds (directory (merge-pathnames "*.asd" root)))
           (dirname (car (last (pathname-directory (uiop:ensure-directory-pathname root))))))
      (or (loop for a in asds
                when (string-equal (pathname-name a) dirname) return (pathname-name a))
          (and asds (pathname-name (first asds)))
          dirname))))
