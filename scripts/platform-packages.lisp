;;;; platform-packages.lisp --- which platform packages should exist on THIS host (pre-publication issue 182).
;;;;
;;;; ONE answer, consumed by both bootstrap.lisp and scripts/verify-tree.lisp. The issue is
;;;; explicit about why it is one file: two implementations of this predicate will drift,
;;;; and the drift is invisible on two of the three OSes.
;;;;
;;;; ECOSYSTEM.md settles the policy this encodes:
;;;;
;;;;   bootstrap.lisp compiles the host OS's platform package -- hades/windows on Windows,
;;;;   hades/darwin on macOS -- rather than leaving it opt-in the way aion/uv is. Opt-in
;;;;   there was BOUGHT by the C-toolchain requirement; a Hades platform package has none
;;;;   (ADR-0003 s8), so deferring it buys nothing and costs the one thing that matters: a
;;;;   subsystem that goes uncompiled on the only OS where it can be compiled at all.
;;;;
;;;; THE ASYMMETRY IS THE WHOLE POINT. `aion/windows' absent on macOS is correct and must be
;;;; silent; absent on Windows it is a defect and must be loud. Those are two different right
;;;; answers, and a single "try it, ignore failures" branch gives the right behaviour on two
;;;; OSes while hiding a real failure on the third. This file exists so the two cases cannot
;;;; share a code path.
;;;;
;;;; PLAIN CL, NO DEPENDENCIES, NOT A MEMBER OF ANY ASDF SYSTEM -- deliberately. bootstrap.lisp
;;;; runs before `cons' exists (it is what BUILDS it), so anything bootstrap consumes cannot
;;;; live in a system. `load' is the only mechanism available to both callers, so this file
;;;; must work under it and must not need ASDF, Quicklisp, or UIOP. The cost is that
;;;; verify-tree cannot compile it as a system component; cons/tests loads it by path and
;;;; exercises it instead, which is where its checks come from.

(defpackage #:ouranos-platform
  (:use #:common-lisp)
  (:export #:host-os #:entries-for #:entries-here
           #:not-applicable-for #:not-applicable-here
           #:entry-system #:entry-status #:entry-issue #:entry-note
           #:required-p #:planned-p #:*platform-packages*))

(in-package #:ouranos-platform)

;;; --- the registry ----------------------------------------------------------
;;;
;;; STATUS is the field that matters, and it carries the same doctrine as +KNOWN-EMPTY+ in
;;; verify-tree.lisp: an exception someone MADE and can be asked about, not one that
;;; accumulated.
;;;
;;;   :required  the system EXISTS in the tree and this host owns it. It must be findable,
;;;              it must build, and its suite must run. Absent or broken is a gate failure.
;;;
;;;   :planned   the system is decided but NOT YET WRITTEN. Absent is the expected state and
;;;              is reported, loudly, without failing -- because a gate that goes red for
;;;              work that has not started yet gets switched off, and a switched-off gate is
;;;              the thing this whole file is defending against.
;;;
;;; A :planned package that turns out to be PRESENT is itself reported: it means the work
;;; landed and this line is now stale. Flipping :planned -> :required is a one-word change,
;;; and it belongs in the pull request that lands the package -- that is the handoff, and it
;;; is why the two states are here rather than inferred from whether ASDF can find the system.
;;; Inferring it would mean a deleted package silently downgrades itself to "not written yet".

(defparameter *platform-packages*
  '((:windows
     (:system "aion/windows"     :status :required :issue "pre-publication issue 170"
      :note "the foundation: UTF-16, GetLastError/HRESULT as conditions, handles, and the layout table")
     (:system "aion/windows/com" :status :required :issue "pre-publication issue 170"
      :note "the first subsystem -- COM is the meta-API (ADR-0003 s5), so it is sequenced first")
     (:system "aion/windows/registry" :status :required :issue "#132"
      :note "reading one value in a NAMED bitness view. Registered here rather than in
             verify-tree's +test-systems+ because that list is host-neutral and this suite
             can only run where the registry exists -- the same reason aion/windows and
             aion/windows/com are here. It shipped with six tests and no entry, so the gate
             never ran them: an unregistered suite and a passing one are identical at the
             exit code, and this one was reported complete on the strength of a code read.")
     (:system "hades/windows"    :status :planned  :issue "pre-publication issue 180"
      :note "the OS ergonomics layer over the binding; hades is not chartered yet"))
    (:darwin
     (:system "hades/darwin"  :status :planned :issue "pre-publication issue 180"))
    (:linux
     (:system "hades/linux"   :status :planned :issue "pre-publication issue 180")))
  "Platform packages by host OS, each with the status that says how to read its absence.

Keyed by the OS that OWNS the package -- the one where it can be compiled at all. Every
other OS gets `not applicable', silently and by design.")

;;; --- accessors --------------------------------------------------------------

(defun entry-system (entry) (getf entry :system))
(defun entry-status (entry) (getf entry :status))
(defun entry-issue  (entry) (getf entry :issue))
(defun entry-note   (entry) (getf entry :note))

(defun required-p (entry) (eq (entry-status entry) :required))
(defun planned-p  (entry) (eq (entry-status entry) :planned))

;;; --- the host ---------------------------------------------------------------

(defun host-os ()
  "This host as one of :WINDOWS, :DARWIN, :LINUX, or NIL for anything else.

Read from *FEATURES* rather than from UIOP, because bootstrap.lisp loads this file and UIOP
is not guaranteed to be present at that point. :WIN32 is SBCL's own and is in a bare image
before ASDF is required -- see the measurement in pre-publication issue 87. :DARWIN likewise."
  (cond ((or (find :win32 *features*) (find :windows *features*)) :windows)
        ((find :darwin *features*) :darwin)
        ((find :linux *features*) :linux)
        (t nil)))

(defun entries-for (os)
  "The platform-package entries OS owns; NIL for an OS with none."
  (cdr (assoc os *platform-packages*)))

(defun entries-here ()
  "The platform-package entries THIS host owns."
  (entries-for (host-os)))

(defun not-applicable-for (os)
  "Every entry owned by some OS OTHER than OS, as (owning-os . entry) pairs.

Reported by the gate rather than dropped. `aion/windows was not checked' and `aion/windows
does not apply here' are the same silence otherwise, and telling them apart on the machine
that CANNOT answer is how a reader of a macOS PASS knows what that PASS does not cover.

Takes OS rather than reading the host, so the asymmetry this file exists for can be TESTED
from any machine. A predicate that can only be exercised on the platform it describes is
checked on one third of the tree and asserted on the rest."
  (let ((out '()))
    (dolist (bucket *platform-packages* (nreverse out))
      (let ((owner (car bucket)))
        (unless (eq owner os)
          (dolist (entry (cdr bucket))
            (push (cons owner entry) out)))))))

(defun not-applicable-here ()
  "NOT-APPLICABLE-FOR this host."
  (not-applicable-for (host-os)))
