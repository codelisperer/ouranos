;;;; platform-tests.lisp --- the platform registry, and the asymmetry it exists for (pre-publication issue 182).
;;;;
;;;; The registry answers "which platform packages should exist on THIS host", and both
;;;; bootstrap.lisp and scripts/verify-tree.lisp consume that one answer so they cannot
;;;; drift. It is plain CL in scripts/ rather than a component of any system, because
;;;; bootstrap runs before `cons' exists -- so it is LOADED here by path.
;;;;
;;;; Testing it from cons is deliberate: cons owns the build/tooling surface, and this is
;;;; build policy. Every assertion below is over a GIVEN os rather than the running one --
;;;; a predicate about three platforms that can only be exercised on the one you happen to
;;;; be sitting at is checked on a third of its behaviour and asserted on the rest, which
;;;; is the shape of defect pre-publication issue 182 was filed about in the first place.

(in-package #:cons/tests)

(def-suite platform :description "The host-platform package registry (pre-publication issue 182)." :in all)
(in-suite platform)

(defun %load-platform-registry ()
  "Load scripts/platform-packages.lisp, the file bootstrap and verify-tree both load.

By PATH and not through ASDF, because that is how its two real callers reach it -- a test
that loaded it some other way would be testing a file the tree does not actually use."
  (let ((path (merge-pathnames "scripts/platform-packages.lisp"
                               (asdf:system-source-directory :cons))))
    ;; cons/ is a framework directory inside the monorepo; the script lives at the ROOT.
    (unless (probe-file path)
      (setf path (merge-pathnames "../scripts/platform-packages.lisp"
                                  (asdf:system-source-directory :cons))))
    (is-true (probe-file path)
             "scripts/platform-packages.lisp must exist -- bootstrap.lisp loads it by path, so a rename breaks the seed, not just this test. Looked at ~A" path)
    (when (probe-file path)
      (load path))
    path))

(defmacro %pf (name &rest args)
  "Call an OURANOS-PLATFORM function by name at RUNTIME.

The package does not exist until %LOAD-PLATFORM-REGISTRY runs, and a literal
`ouranos-platform:host-os' would be resolved by the READER -- taking the whole test system
down with a package error on any tree where the file has moved. Same reasoning as the
sb-posix lookup in packages.lisp."
  `(funcall (read-from-string ,(concatenate 'string "ouranos-platform:" (string-downcase (string name))))
            ,@args))

(test registry-loads-in-a-bare-image
  "bootstrap.lisp loads this file with no ASDF systems built and, on a cold machine, no
Quicklisp yet. So it must depend on nothing -- if it ever grows a UIOP call, the seed breaks
on the one path nobody runs twice."
  (%load-platform-registry)
  (is-true (find-package "OURANOS-PLATFORM")
           "loading the registry must define its package")
  (is-true (listp (symbol-value (read-from-string "ouranos-platform:*platform-packages*")))
           "the registry must be plain data"))

(test every-entry-is-well-formed
  "A malformed entry would be read as `no platform packages here', which is silence -- and
silence is the failure mode this registry exists to remove."
  (%load-platform-registry)
  (dolist (os '(:windows :darwin :linux))
    (dolist (entry (%pf entries-for os))
      (let ((system (%pf entry-system entry))
            (status (%pf entry-status entry))
            (issue  (%pf entry-issue entry)))
        (is (stringp system) "~A entry has a non-string :system -- ~S" os entry)
        (is (member status '(:required :planned))
            "~A entry ~A has status ~S; only :required and :planned are readable by the gate"
            os system status)
        (is (stringp issue)
            "~A entry ~A carries no :issue -- a planned package with no ticket is a package nobody is going to write"
            os system)))))

(test each-package-is-owned-by-exactly-one-os
  "A package owned by two hosts has no single right answer for `is its absence a defect',
which is precisely the question the registry is here to settle."
  (%load-platform-registry)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (os '(:windows :darwin :linux))
      (dolist (entry (%pf entries-for os))
        (let ((system (%pf entry-system entry)))
          (is (null (gethash system seen))
              "~A is owned by both ~A and ~A" system (gethash system seen) os)
          (setf (gethash system seen) os))))))

(test the-asymmetry-holds-from-every-os
  "THE POINT OF THE WHOLE FILE. `aion/windows' absent on macOS is correct and silent; absent
on Windows it is a defect and loud. Asserted from all three perspectives on one machine,
because two of the three are otherwise never checked anywhere."
  (%load-platform-registry)
  (let ((windows-systems (mapcar (lambda (e) (%pf entry-system e)) (%pf entries-for :windows))))
    (is-true (member "aion/windows" windows-systems :test #'string=)
             "windows must own aion/windows (pre-publication issue 170); it owns ~S" windows-systems)
    ;; From macOS and Linux the same package must be NOT APPLICABLE -- present in the
    ;; not-applicable list, absent from the owned list.
    (dolist (os '(:darwin :linux))
      (let ((owned (mapcar (lambda (e) (%pf entry-system e)) (%pf entries-for os)))
            (n/a   (mapcar (lambda (pair) (%pf entry-system (cdr pair)))
                           (%pf not-applicable-for os))))
        (is-false (member "aion/windows" owned :test #'string=)
                  "~A must not own aion/windows" os)
        (is-true (member "aion/windows" n/a :test #'string=)
                 "~A must report aion/windows as not applicable, NOT merely omit it -- omission and `did not check' are the same silence" os)))))

(test not-applicable-never-includes-what-this-os-owns
  "The complement has to be exact in both directions, or the gate double-reports a package
as both covered and not applicable."
  (%load-platform-registry)
  (dolist (os '(:windows :darwin :linux))
    (let ((owned (mapcar (lambda (e) (%pf entry-system e)) (%pf entries-for os)))
          (n/a   (mapcar (lambda (pair) (%pf entry-system (cdr pair)))
                         (%pf not-applicable-for os))))
      (dolist (system owned)
        (is-false (member system n/a :test #'string=)
                  "~A owns ~A and also lists it as not applicable" os system))
      ;; and together they account for every package in the registry
      (is (= (+ (length owned) (length n/a))
             (loop for bucket in (symbol-value (read-from-string "ouranos-platform:*platform-packages*"))
                   sum (length (cdr bucket))))
          "~A: owned (~D) + not-applicable (~D) must cover every registered package"
          os (length owned) (length n/a)))))

(test host-os-agrees-with-uiop
  "HOST-OS reads *FEATURES* directly because UIOP is not guaranteed present when bootstrap
loads the registry. That freedom is only safe while the two agree, so pin it.

Note what is NOT asserted. `(uiop:os-unix-p)` is true on every Unix, but HOST-OS documents
returning one of :WINDOWS / :DARWIN / :LINUX or NIL for ANYTHING ELSE -- so on a BSD it
returns NIL and is behaving exactly as specified. Asserting :LINUX for any Unix host would
make this test fail on a host where the code is CORRECT, and a test that contradicts the
contract is one somebody eventually satisfies by changing the code. Ouranos supports no BSD
today, which is exactly why this could sit here unnoticed until the one day it fired."
  (%load-platform-registry)
  (let ((host (%pf host-os)))
    (cond ((uiop:os-windows-p) (is (eq :windows host) "uiop says Windows, registry says ~S" host))
          ((uiop:os-macosx-p)  (is (eq :darwin host)  "uiop says macOS, registry says ~S" host))
          ;; :LINUX in *FEATURES* is the thing HOST-OS actually reads -- so this asks the
          ;; question the contract answers, rather than a broader one it never promised.
          ((find :linux *features*) (is (eq :linux host) "features say Linux, registry says ~S" host))
          ((uiop:os-unix-p)
           (is (null host)
               "a Unix that is not Linux or macOS is documented to be NIL, got ~S" host))
          (t (skip "no uiop OS predicate matched this host; nothing to agree with")))))

(test entries-here-is-entries-for-this-host
  "The two callers use ENTRIES-HERE; the tests above exercise ENTRIES-FOR. They must be the
same function applied to the host, or the tested path is not the shipped one."
  (%load-platform-registry)
  (is (equal (%pf entries-for (%pf host-os))
             (%pf entries-here))
      "ENTRIES-HERE must be ENTRIES-FOR of HOST-OS"))
