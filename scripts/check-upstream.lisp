;;;; check-upstream.lisp --- every pinned version in the tree has an entry in upstream.sexp, and
;;;; every entry still finds its pin (#716).
;;;;
;;;;     sbcl --script scripts/check-upstream.lisp                     ; offline, deterministic
;;;;     sbcl --script scripts/check-upstream.lisp --online [--markdown FILE]
;;;;     sbcl --script scripts/check-upstream.lisp --self-test         ; the comparison rules
;;;;
;;;; Exit 0 when the inventory and the tree agree, 1 when they do not, 2 when upstream.sexp
;;;; cannot be read at all, so a misread inventory is never reported as a clean one.
;;;;
;;;; WHAT IT CHECKS, all without the network:
;;;;
;;;;   1. Every entry in upstream.sexp is well formed: a unique name, a known category, at
;;;;      least one place in :WHERE, a known :UPSTREAM form, and a :REVIEWED date or :NEVER
;;;;      when the upstream is :MANUAL.
;;;;   2. Every place an entry names still yields a value, and all of them yield the same one.
;;;;      A pin that moved, or a second copy of a version that was not updated with the first
;;;;      (libuv.pin's version and url lines, ASSETS.pin and assets.lisp), fails here.
;;;;   3. Every pin in the tree has an entry. The places a pin is looked for:
;;;;        - each identity line of each *.pin file (`version' or `sha', or an ASSETS.pin-style
;;;;          `NAME VERSION sha256 HASH' line);
;;;;        - each *_VERSION key and QUICKLISP_DIST in scripts/versions.env;
;;;;        - in each workflow: each `uses: ACTION@', each `runs-on:' and matrix `os:' value (a
;;;;          runner image), and each *_VERSION or *_COMMIT key of an `env:' block (#749);
;;;;        - each `image:' line of a compose file at the top of the tree, and each `image=' line
;;;;          of a script in scripts/ (#749).
;;;;      A pin added in one of those places without an entry fails here, in the commit that
;;;;      added it. A version written anywhere else, such as an API version or a default model
;;;;      id in Lisp source, has no fixed shape to look for: its entry's :WHERE is its only
;;;;      coverage, and nothing reports such a pin when it has no entry.
;;;;
;;;; WITH --ONLINE it then asks each entry's upstream for its latest release and prints, per
;;;; entry, current, behind, held (behind on purpose, with the reason and issue), manual (an API
;;;; version checked by hand, with its review date), or unknown (the source could not be reached
;;;; or read; never reported as current). It exits 0 whatever it finds. It needs the network, so
;;;; it runs in .github/workflows/upstream.yml and never in the gate (docs/versioning-and-pinning.md).

;;;; THE CODE LIVES IN cons (#716, point 4). The offline core is cons/src/inventory.lisp, loaded
;;;; here as a plain file so this script still needs nothing but SBCL; the online half is the
;;;; system cons/outdated, loaded only for --online. What this file keeps is the command line:
;;;; which tree, which mode, and the exit codes.

(require :uiop)
(defparameter *scripts* (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
(load (merge-pathnames "human-path.lisp" *scripts*))   ; how a path is printed (#168)
(load (merge-pathnames "pin-files.lisp" *scripts*))    ; which *.pin files are read (#808)
(load (merge-pathnames "../cons/src/inventory.lisp" *scripts*))

(setf cons/inventory:*root* (uiop:pathname-parent-directory-pathname *scripts*))

(defun load-online-dependencies ()
  "Quicklisp and this tree's cons/outdated, which brings aion/http-client and jzon. The tree is
registered with ASDF the way bootstrap.lisp's drop-in registers it, so the client is this tree's
own."
  (require :asdf)
  (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
  (funcall (read-from-string "asdf:initialize-source-registry")
           `(:source-registry (:tree ,cons/inventory:*root*) :inherit-configuration))
  (funcall (read-from-string "ql:quickload") :cons/outdated :silent t))

(defun report-problems-and-exit ()
  (dolist (p (reverse cons/inventory:*problems*))
    (format t "  PROBLEM ~A~%" p))
  (format t "check-upstream: ~D problem~:P. See upstream.sexp's header.~%" (length cons/inventory:*problems*))
  (uiop:quit 1))

(defun main (args)
  (cond ((member "--self-test" args :test #'string=)
         (uiop:quit (if (zerop (cons/inventory:self-test)) 0 1)))
        (t
         (let ((checked (handler-case (cons/inventory:offline-check)
                          (cons/inventory:inventory-unreadable (c)
                            (format *error-output* "~A~%" c)
                            (uiop:quit 2)))))
           (when cons/inventory:*problems* (report-problems-and-exit))
           (cond ((member "--online" args :test #'string=)
                  (load-online-dependencies)
                  (uiop:symbol-call :cons/outdated :report-online
                                    checked (second (member "--markdown" args :test #'string=)))
                  ;; Being behind is a fact to act on, not a broken build.
                  (uiop:quit 0))
                 (t (format t "check-upstream: upstream.sexp and the tree agree.~%")
                    (uiop:quit 0)))))))

(main (rest sb-ext:*posix-argv*))
