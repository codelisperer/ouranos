;;;; registry-tests.lisp --- the bitness axis, against classes this machine really has.
;;;;
;;;; THE FIXTURE IS THE INTERESTING PART AND IT COSTS NOTHING TO INSTALL. Any 64-bit Windows
;;;; with Office already carries all three cases this subsystem exists to tell apart:
;;;;
;;;;   Microsoft.Jet.OLEDB.4.0   32-bit view only  -- there is no 64-bit Jet and never was
;;;;   Microsoft.ACE.OLEDB.16.0  64-bit view only  -- a 64-bit Office install
;;;;   Scripting.Dictionary      BOTH views        -- ships with Windows
;;;;
;;;; Jet is the one that matters. It is not a broken install; it is installed, for the other
;;;; bitness, on a machine nobody touched. A probe that resolves the ProgID and stops answers
;;;; YES for a provider a 64-bit process can never create -- which is the cheaper
;;;; implementation people reach for, and it is wrong here by default.
;;;;
;;;; EVERY TEST SKIPS RATHER THAN FAILS WHEN ITS CLASS IS ABSENT, and the skip says which.
;;;; A machine without Office has no ACE and possibly no Jet, and a red suite there would be
;;;; a claim about this code rather than about that machine.

(in-package #:aion/windows/registry/tests)
(in-suite registry)

(defparameter +jet+ "Microsoft.Jet.OLEDB.4.0")
(defparameter +ace+ "Microsoft.ACE.OLEDB.16.0")
(defparameter +dict+ "Scripting.Dictionary")

(defun %clsid (prog-id)
  (or (reg:prog-id-clsid prog-id :64) (reg:prog-id-clsid prog-id :32)))

(test a-view-is-required-and-checked
  "VIEW has no default, deliberately, and a wrong one is caught rather than guessed at.
The whole subsystem exists because the answer differs by view."
  (signals error (reg:key-default-value "CLSID" :both))
  (signals error (reg:key-default-value "CLSID" nil)))

(test an-absent-key-is-NIL-not-an-error
  "Absence is the common answer and the one a capability check is usually asking about. A
lookup that signals cannot be built on -- see pre-publication issue 306: a predicate that signals cannot be asked."
  (is (null (reg:key-default-value "No.Such.Class.Here\CLSID" :64)))
  (is (null (reg:key-default-value "No.Such.Class.Here\CLSID" :32)))
  (is (null (reg:class-inproc-server "{00000000-0000-0000-0000-000000000000}" :64))))

(test a-class-present-in-both-views-reads-in-both
  "Scripting.Dictionary ships with Windows in both bitnesses. The control: without it, a
binding that always answered NIL for one view would pass every other test here."
  (let ((clsid (%clsid +dict+)))
    (if (null clsid)
        (skip "~A is not registered on this machine" +dict+)
        (let ((in-64 (reg:class-inproc-server clsid :64))
              (in-32 (reg:class-inproc-server clsid :32)))
          (is (stringp in-64) "expected a 64-bit InprocServer32 for ~A" +dict+)
          (is (stringp in-32) "expected a 32-bit InprocServer32 for ~A" +dict+)
          ;; And they are DIFFERENT files -- System32 against SysWOW64. Identical strings
          ;; would mean the view flag was ignored and both reads hit the same key.
          (is (not (string-equal in-64 in-32))
              "the two views must resolve to different files; both said ~S" in-64)))))

(test the-view-flag-is-not-ignored
  "THE DISCRIMINATING TEST, and the one a creation-only predicate cannot perform. Jet 4.0 is
registered for 32-bit ONLY. If the view argument were ignored -- or if both reads silently
hit the process's own view -- this class would look either present in both or absent in both,
and the OTHER-BITNESS case would be invisible."
  (let ((clsid (%clsid +jet+)))
    (if (null clsid)
        (skip "~A is not registered on this machine" +jet+)
        (let ((in-64 (reg:class-inproc-server clsid :64))
              (in-32 (reg:class-inproc-server clsid :32)))
          (is (null in-64)
              "there is no 64-bit Jet; got ~S" in-64)
          (is (stringp in-32)
              "but it IS installed for 32-bit -- that is the whole distinction")
          (is (search "msjetoledb40" (string-downcase in-32))
              "and the 32-bit view names the Jet provider: ~S" in-32)))))

(test the-mirror-case-reads-the-other-way
  "ACE 16 on a 64-bit Office: present in the 64-bit view and absent in the 32-bit one. Jet
alone could be satisfied by a binding that always returned NIL for :64; this cannot."
  (let ((clsid (%clsid +ace+)))
    (if (null clsid)
        (skip "~A is not registered on this machine (no 64-bit Office)" +ace+)
        (let ((in-64 (reg:class-inproc-server clsid :64))
              (in-32 (reg:class-inproc-server clsid :32)))
          (is (stringp in-64) "expected a 64-bit ACE provider")
          (is (search "aceoledb" (string-downcase in-64))
              "and it names ACE: ~S" in-64)
          (is (null in-32) "and no 32-bit one on this machine; got ~S" in-32)))))

(test the-value-read-is-a-path-that-exists
  "Reporting WHICH FILE is the point (#129), so the file has to be real. A read that
truncated the string, or dropped the terminating NUL handling, would still return a
plausible-looking string and this is what catches it."
  (let ((clsid (%clsid +dict+)))
    (if (null clsid)
        (skip "~A is not registered on this machine" +dict+)
        (let ((path (reg:class-inproc-server clsid :64)))
          (is (stringp path))
          (is (probe-file path)
              "InprocServer32 named ~S, which is not a file -- a truncated read looks
exactly like this" path)))))
