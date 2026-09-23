;;;; install-deps.lisp --- install every third-party system this tree needs, and nothing else.
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script scripts/install-deps.lisp
;;;;   sbcl --dynamic-space-size 4096 --script scripts/install-deps.lisp --list
;;;;
;;;; Exit 0 when every external dependency is installed and loadable, 1 otherwise.
;;;;
;;;; WHY THIS EXISTS, and it is a distinction that cost a red CI run to see clearly:
;;;;
;;;; `asdf:load-system` RESOLVES dependencies but never FETCHES them. `ql:quickload`
;;;; fetches. scripts/verify-tree.lisp deliberately uses the former -- quickload does not
;;;; escalate a compile-time WARNING to a failure, so a system ASDF refuses to build loads
;;;; clean under it. On a developer's machine the difference is invisible, because the
;;;; dependencies are already there. On a CI runner, which has installed NOTHING, every
;;;; system with an external dependency fails to load and the tree reports FAIL for a
;;;; reason that has nothing to do with the code.
;;;;
;;;; The obvious fix -- let bootstrap.lisp warm the stack first -- is wrong, and quietly so.
;;;; Warming compiles OUR tree with quickload, and once a fasl exists the file is merely
;;;; LOADED afterwards. Coalton reports an unused binding as a full WARNING that ASDF
;;;; escalates to a build failure, so a warm tree makes verify-tree unable to see the exact
;;;; class of defect it exists to catch (AGENTS.md, "Green is not evidence";
;;;; docs/coalton-patterns.md 8a). The gate must do the compiling.
;;;;
;;;; So this installs THIRD-PARTY SYSTEMS ONLY. Our own code is never compiled here --
;;;; `asdf:find-system` reads a .asd without building it, which is what makes the set
;;;; computable before a cold build rather than after one.

(require :asdf)
(require :uiop)

;;; Quicklisp FIRST: it reinitialises the source registry when it loads, so tree-deps.lisp
;;; (which pins the registry to this tree) must come after it, not before.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *scripts*
  (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))

(load (merge-pathnames "tree-deps.lisp" *scripts*))

(let* ((list-only (member "--list" (uiop:command-line-arguments) :test #'string=))
       (all (tree-deps:external-dependencies))
       ;; APPLICABLE-ONLY, and the Windows CI leg is why. praxeon/web declares
       ;; `(:feature (:not :windows) "clack-handler-woo")` because Woo binds libev, which
       ;; does not build on Windows -- so asking Quicklisp for it there is asking for a
       ;; system that cannot exist on the platform. The tree was already right; the
       ;; enumeration was flattening the guard away.
       (externals (tree-deps:external-dependencies :applicable-only t))
       (not-here (remove-if (lambda (n) (member n externals :test #'string=)) all))
       (failed '()))

  ;; WHAT THIS PLATFORM ACTUALLY THINKS IT IS, printed rather than assumed.
  ;;
  ;; A (:feature ...) guard is only as good as the keyword in it, and a keyword that is in
  ;; NO implementation's *features* is not a guard at all -- it silently inverts, selecting
  ;; the branch meant for everyone else. That is not hypothetical: praxeon/web guarded on a
  ;; bare `:windows`, and the Windows CI leg selected the Unix branch and died loading
  ;; libev. Worse, whether such a keyword is present can depend on LOAD ORDER, because
  ;; libraries push their own normalising features -- so the same tree can resolve
  ;; differently depending on what happened to be loaded first.
  ;;
  ;; `:os-windows` is the one to guard on here: UIOP maintains it, and ASDF is loaded
  ;; before any .asd is read, so it cannot be absent at the moment a guard is evaluated.
  (format t "~&~%=== what this image thinks the platform is ===~%")
  (dolist (f '(:os-windows :os-unix :os-macosx :win32 :windows :unix :darwin :linux))
    (format t "  ~(~a~)~20t~a~%" f (if (member f *features*) "present" "-")))
  (format t "  uiop:os-windows-p~20t~a~%" (if (uiop:os-windows-p) "T" "NIL"))

  (format t "~&~%=== third-party systems this tree declares (~D) ===~%" (length all))
  (format t "~{  ~a~%~}" all)

  ;; NAMED, not silently dropped. A step that quietly installs fewer things than the tree
  ;; declares reads as full coverage, which is the failure this repo keeps catching one
  ;; level up. If a dependency is missing here, it should be because a guard says so.
  (when not-here
    (format t "~%=== not applicable to this platform (~D) ===~%" (length not-here))
    (format t "~{  ~a~%~}" not-here))
  (when (and (null not-here) (< (length externals) (length all)))
    (format t "~%(counts disagree with no names -- that is a bug in this script)~%"))

  (when list-only (uiop:quit 0))

  (format t "~%=== installing ===~%")
  (dolist (name externals)
    ;; One at a time, not one quickload of the whole list: a single failure in a batch
    ;; reports one condition and hides which of thirty names caused it. The point of this
    ;; script running before the gate is that when it fails, it says what to fix.
    (handler-case
        (progn (funcall (read-from-string "ql:quickload") name :silent t)
               (format t "  ok      ~a~%" name))
      (error (e)
        (format t "  FAIL    ~a~%          ~a~%" name e)
        (push name failed))))

  (if failed
      (progn
        (format t "~%~D of ~D could not be installed:~%~{  - ~a~%~}"
                (length failed) (length externals) (reverse failed))
        (format t "~%Two usual causes. The name is not in the pinned Quicklisp dist (see~%")
        (format t "scripts/versions.env) -- the dist moved, or the dependency is new and~%")
        (format t "undocumented, which docs/dependencies.md and scripts/check-deps.lisp are the~%")
        (format t "pair that should have caught. Or it does not build on this platform, in which~%")
        (format t "case the .asd should say so with a (:feature ...) guard rather than the~%")
        (format t "installer discovering it.~%")
        (uiop:quit 1))
      (progn
        (format t "~%all ~D applicable installed. NOTE: only third-party code was compiled~%"
                (length externals))
        (format t "here -- this tree's own systems are deliberately left uncompiled, so that~%")
        (format t "scripts/verify-tree.lisp does the building and can see the warnings.~%")
        (uiop:quit 0))))
