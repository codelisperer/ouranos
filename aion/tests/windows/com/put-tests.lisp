;;;; put-tests.lisp --- writing a property, which this binding could not do (#306).
;;;;
;;;; `invoke-method', `get-property' and `invoke' were exported and there was NO SETTER, so
;;;; any Automation object configured through properties rather than arguments was half
;;;; usable -- most of Office, ADO's Connection, every WMI object.
;;;;
;;;; THE INTENT WAS PRESENT AND THE MECHANISM WAS NOT, which is the part worth remembering.
;;;; +dispatch-property-put+ and +dispid-property-put+ were both defined AND exported, and
;;;; %invoke carried an `if' on property-put whose two branches were identical. A reader
;;;; checking whether puts were supported found a constant, an export and a branch, and
;;;; every one of them said yes.
;;;;
;;;; What was actually missing is not a flag. IDispatch requires the new value as a NAMED
;;;; argument -- rgdispidNamedArgs[0] = DISPID_PROPERTYPUT, cNamedArgs = 1 -- and %invoke
;;;; passed 0. The constants alone would never have been enough.
;;;;
;;;; Scripting.Dictionary, because it ships with Windows, needs nothing installed, and has
;;;; both kinds of property in one object: CompareMode is plain, Item is indexed. Those are
;;;; different shapes at the interface and a binding can get one right and the other wrong.

(in-package #:aion/windows/com/tests)

(def-suite property-put :description "Writing properties on a live COM server." :in all)
(in-suite property-put)

(defmacro with-dictionary ((var) &body body)
  `(handler-case
       (com:with-com-object (,var (com:create-object "Scripting.Dictionary"))
         ,@body)
     (com:com-error (e)
       (skip "Scripting.Dictionary is not available on this machine (~A)" (type-of e)))))

(test a-plain-property-can-be-written
  "CompareMode: a scalar property, put with no index."
  (with-dictionary (d)
    (is (eql 0 (com:get-property d "CompareMode")) "starts at the default")
    (com:set-property d "CompareMode" 1)
    (is (eql 1 (com:get-property d "CompareMode"))
        "and the server kept the value we wrote")))

(test an-indexed-property-can-be-written
  "Item(key): an indexed property, so the value is the LAST argument and the index precedes
it. Getting this backwards is the natural mistake and the server cannot tell you -- it would
simply write the index into the slot named by the value."
  (with-dictionary (d)
    (com:invoke-method d "Add" "k" "original")
    (is (string= "original" (com:get-property d "Item" "k")))
    (com:set-property d "Item" "k" "written")
    (is (string= "written" (com:get-property d "Item" "k"))
        "the value went to the key, not the other way round")))

(test writing-an-existing-key-replaces-rather-than-adds
  "THE CHECK THAT DISTINGUISHES A PUT FROM A CALL. Dictionary's Item put ADDS the key when it
is absent, so a binding that reached the member by some other route -- or wrote to the wrong
slot -- would still leave the value readable and would leave Count at 2. Asserting the value
alone cannot see that; asserting Count can."
  (with-dictionary (d)
    (com:invoke-method d "Add" "k" "original")
    (com:set-property d "Item" "k" "written")
    (is (eql 1 (com:get-property d "Count"))
        "a put on an existing key must replace it, not add a second")))

(test a-put-does-not-disturb-the-getter
  "The two share %invoke and now differ by a named-argument array. A put that left
cNamedArgs set would break the next get on the same object, which a single-call test cannot
see -- so this does both, in order, on one object."
  (with-dictionary (d)
    (com:set-property d "CompareMode" 1)
    (com:invoke-method d "Add" "a" "1")
    (is (string= "1" (com:get-property d "Item" "a")) "a get still works after a put")
    (com:set-property d "Item" "a" "2")
    (is (string= "2" (com:get-property d "Item" "a")) "and a put still works after a get")))
