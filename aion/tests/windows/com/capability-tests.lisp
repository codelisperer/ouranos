;;;; capability-tests.lisp --- the three answers, against classes this machine really has.
;;;;
;;;; THE CASE THAT MATTERS IS THE ONE A CREATION-ONLY PREDICATE CANNOT SEE. Under WOW64 a
;;;; class registered for the other bitness and a class never installed both come back
;;;; REGDB_E_CLASSNOTREG, so a suite exercising only the creatable path passes against a
;;;; predicate that gives the wrong advice in the case it exists for.
;;;;
;;;; The fixture costs nothing to install. Any 64-bit Windows with Office carries all three:
;;;;
;;;;   Microsoft.Jet.OLEDB.4.0   registered 32-bit ONLY -- there is no 64-bit Jet, ever
;;;;   Microsoft.ACE.OLEDB.16.0  registered 64-bit only on a 64-bit Office
;;;;   Scripting.Dictionary      both views, ships with Windows
;;;;
;;;; Jet alone would be satisfied by a predicate that answered OTHER-BITNESS for anything it
;;;; could not create, so ACE is here to rule that out: it is in the other view's blind spot
;;;; in the mirror direction and must still answer PRESENT.

(in-package #:aion/windows/com/tests)

(def-suite capability :description "Is this COM class actually here, and which one." :in all)
(in-suite capability)

(test an-unregistered-class-is-absent-with-no-path
  "No ProgID, no CLSID, nothing to report -- and NIL rather than a signal, because a
predicate that signals cannot be asked."
  (multiple-value-bind (ok why path) (com:class-available-p "Nothing.Registered.Here.At.All")
    (is (null ok))
    (is (eq :absent why))
    (is (null path) "there is no file to name; got ~S" path)))

(test a-class-in-this-view-is-present-and-names-its-file
  "Scripting.Dictionary ships with Windows in both bitnesses, so it is PRESENT whichever
process asks. THE PATH IS THE ASSERTION: reporting it on the SUCCESS path is the half nobody
requests, and #129 is what happens without it -- mnemosyne reported a green SQLite backend
for months on a DLL an unrelated install supplied, with every layer honest except which file
answered."
  (multiple-value-bind (ok why path) (com:class-available-p "Scripting.Dictionary")
    (if (not (eq why :present))
        (skip "Scripting.Dictionary is not registered here (~A)" why)
        (progn
          (is (eq t ok))
          (is (stringp path) "PRESENT must name the file it found")
          (is (probe-file path) "and that file must exist: ~S" path)
          (is (search "scrrun" (string-downcase path))
              "and be the one we expect: ~S" path)))))

(test a-class-registered-for-the-other-bitness-says-so
  "THE WHOLE POINT. Jet 4.0 is registered 32-bit only, so a 64-bit process cannot create it
-- and CoCreateInstance reports that identically to never-installed. Answering :ABSENT here
would send a user to install something already on their machine, which is the most expensive
error in this space and the reason the registry is consulted at all."
  (multiple-value-bind (ok why path) (com:class-available-p "Microsoft.Jet.OLEDB.4.0")
    (if (eq why :absent)
        (skip "Jet 4.0 is not registered on this machine at all")
        (progn
          (is (null ok) "a class this process cannot create is not available")
          (is (eq :other-bitness why)
              "it must be distinguished from absent; got ~S" why)
          (is (stringp path) "and it must name the build that IS installed")
          (is (probe-file path) "which is a real file: ~S" path)))))

(test the-mirror-direction-is-not-swallowed
  "ACE 16 sits in the opposite blind spot: on a 64-bit Office it is registered 64-bit only.
A predicate that answered :OTHER-BITNESS for anything it could not immediately create would
pass the Jet test and fail here, which is why both are present."
  (multiple-value-bind (ok why path) (com:class-available-p "Microsoft.ACE.OLEDB.16.0")
    (if (eq why :absent)
        (skip "ACE 16 is not installed on this machine")
        (progn
          (is (eq t ok) "ACE is creatable from this process")
          (is (eq :present why) "and PRESENT rather than other-bitness; got ~S" why)
          (is (search "aceoledb" (string-downcase path)) "naming ACE: ~S" path)))))

(test asking-does-not-leave-a-server-running
  "A predicate is a question, not an acquisition. Creation is released immediately, so asking
repeatedly must not accumulate anything -- an out-of-process server left running because
somebody checked whether it existed is a side effect a capability check must not have."
  (dotimes (i 5)
    (multiple-value-bind (ok why) (com:class-available-p "Scripting.Dictionary")
      (declare (ignore ok))
      (is (member why '(:present :absent))
          "answer ~D must be stable, got ~S" i why))))

(test the-answer-survives-being-asked-about-rubbish
  "Never signals is a contract, not an aspiration. Empty strings, a ProgID-shaped string
with no registration, and a raw CLSID are all things a caller will pass eventually."
  (finishes (com:class-available-p ""))
  (finishes (com:class-available-p "not a prog id at all"))
  (finishes (com:class-available-p "{00000000-0000-0000-0000-000000000000}")))
