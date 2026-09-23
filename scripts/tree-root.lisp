;;;; tree-root.lisp --- which checkout is this run about? (#450, #480)
;;;;
;;;; Loaded by every script in this directory that reads or writes the tree. It answers one
;;;; question and refuses to guess at it.
;;;;
;;;; THE QUESTION IS NOT `WHERE DOES THIS CODE LIVE'. That is what `*load-truename*' answers,
;;;; and for a long time it was what these scripts used. The question is `which tree did you
;;;; mean', and the only thing that expresses that is where the caller is standing. Run one
;;;; checkout's copy of a script from another and the two answers differ; before #450 the
;;;; script took its own and said nothing.
;;;;
;;;; For check-readme-counts.lisp that meant rewriting a README in a checkout the operator
;;;; had never named, and reporting `VERDICT: UPDATED' -- success, because from where the
;;;; script sat everything had gone right. The caller's tree stayed clean, which is why it
;;;; went unnoticed: there is no local diff to look at.
;;;;
;;;; SO CWD DECIDES, AND A DISAGREEMENT IS REFUSED RATHER THAN RESOLVED. Nothing here can
;;;; tell which tree was meant, and picking either is how it picked wrong before.
;;;;
;;;; NOT A `--root' FLAG. Being unable to point one of these scripts at an arbitrary tree is
;;;; the property that makes the class safe; a flag would make the wrong-tree write a
;;;; supported operation rather than an impossible one. (The reason originally given for that
;;;; refusal -- that check-source-deps already errors when run from outside its tree -- was
;;;; false, and is corrected in scripts/tests/checkers.lisp. The refusal stands; only its
;;;; justification was wrong.)

(require :uiop)

(defpackage #:tree-root
  (:use #:cl)
  (:export #:+markers+ #:checkout-root #:same-directory-p #:resolve #:resolve-or-die))

(in-package #:tree-root)

(defparameter +markers+ '("bootstrap.lisp" "scripts/verify-tree.lisp")
  "What identifies a checkout of THIS repo.

NOT `.git', which is present in every repository on the machine and would let a neighbouring
project -- or an enclosing one -- look like a match.

NOT `README.md' alone, and not `README.md' + `AGENTS.md': twenty directories in this tree
carry a README and three carry an AGENTS.md, so either pair would make `klio/' and `hermes/'
look like roots. A run from inside one of those would then `disagree' with the real root and
be refused, which is a false positive in the guard and would break the gate from a
subdirectory -- the one thing #480 says to assert rather than assume.

The seed and the gate instead. Both sit only at the root -- `find . -name bootstrap.lisp'
and `find . -name verify-tree.lisp' each return exactly one path -- and both have been there
far longer than this file has.

NOT this file, which was the first choice and was wrong: a marker that only exists in trees
carrying THIS change makes every older checkout read as `not a checkout at all', so the
refusal message blames the operator for standing somewhere strange instead of naming the two
trees. Measured against a checkout of main, which is exactly the case an operator will hit.")

(defun checkout-root (start)
  "The checkout containing START, or NIL. Walks up until every marker is present.

Walking up is what lets the gate run from a subdirectory of its own tree, which it must."
  (let ((dir (uiop:ensure-directory-pathname start)))
    (loop
      (when (every (lambda (m) (probe-file (merge-pathnames m dir))) +markers+)
        (return dir))
      (let ((parent (uiop:pathname-parent-directory-pathname dir)))
        (when (equal parent dir) (return nil))
        (setf dir parent)))))

(defun same-directory-p (a b)
  "Do A and B name the same directory on disk? TRUENAME, so a symlinked path and its target
are one answer rather than two."
  (and a b (equal (namestring (truename a)) (namestring (truename b)))))

(defun shown (dir)
  "DIR as this message should print it: TRUENAME first, then native.

THE TWO PATHS IN THE REFUSAL BELOW COME FROM DIFFERENT PLACES AND WERE SPELLED DIFFERENTLY
(#510). `caller-root' is walked up from `uiop:getcwd', which preserves whatever spelling the
caller used; `script-root' comes from a script's `*load-truename*', and TRUENAME resolves a
Windows 8.3 alias to the long name. On a host whose TEMP is the aliased spelling -- which is
what GitHub's Windows runners set -- the same directory printed as `C:\Users\RUNNER~1\...'
on one line and `C:\Users\runneradmin\...' on the next.

That is worse than an untidy message. This text exists to tell a reader WHICH TWO TREES
disagreed, and two spellings of one directory assert a disagreement that is not there,
pointing whoever reads it at a difference they cannot find. So both sides are canonicalised
to one spelling before printing.

The comparison was never affected: `same-directory-p' truenames both sides already, so the
guard has always fired on the right condition. Only what it then said was wrong.

Unguarded TRUENAME is safe here because the only caller is the refusal branch below, which
`same-directory-p' has just truenamed both of these successfully to reach."
  (uiop:native-namestring (truename dir)))

(defun resolve (script-truename)
  "(values ROOT NIL) for the checkout this run is about, or (values NIL MESSAGE).

SCRIPT-TRUENAME is the calling script's own `*load-truename*'. Returns rather than quits, so
each script can report under its own name -- a message beginning `check-pins:' when
check-pins refuses is worth more than a shared prefix naming this file, which the reader did
not run."
  (let* ((script-root (uiop:pathname-parent-directory-pathname
                       (uiop:pathname-directory-pathname script-truename)))
         (caller-root (checkout-root (uiop:getcwd))))
    (cond
      ((null caller-root)
       (values nil (format nil "run this from inside the checkout you mean -- ~A is not in one (looked for ~{`~A'~^ and ~} upwards). These scripts used to take the checkout the SCRIPT lives in, which is how one of them wrote to a tree its caller had never named (#450)."
                           (uiop:native-namestring (uiop:getcwd)) +markers+)))
      ((not (same-directory-p caller-root script-root))
       (values nil (format nil "this script lives in one checkout and you are standing in another, so `which tree' has two answers and nothing here can tell which you meant (#450, #480).~%  you are in:    ~A~%  script is in:  ~A~%Run that tree's own copy: cd into the checkout you mean and use its scripts/."
                           (shown caller-root)
                           (shown script-root))))
      (t (values caller-root nil)))))

(defun resolve-or-die (script-truename prefix &optional (code 2))
  "RESOLVE, or print under PREFIX and quit with CODE."
  (multiple-value-bind (root message) (resolve script-truename)
    (or root
        (progn (format *error-output* "~&~A: ~A~%" prefix message)
               (uiop:quit code)))))
