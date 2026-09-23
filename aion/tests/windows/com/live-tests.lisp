;;;; live-tests.lisp --- a real COM server, called for real.
;;;;
;;;; Scripting.FileSystemObject is deliberate: it ships with every Windows install, needs
;;;; nothing installed and no Office, and it exposes methods taking zero, one, two AND three
;;;; arguments -- which is what makes it the right server to prove this binding on.
;;;;
;;;; THE TWO-ARGUMENT CALL IS THE HEADLINE. Both of this binding's motivating defects
;;;; converge on it:
;;;;
;;;;   the VARIANT sizing bug   under-allocated the argument array and strode 16 bytes per
;;;;                            element on x64, so argument 0 landed and the rest was garbage;
;;;;   the rgvarg ordering      is REVERSED, so a binding that fills it forwards passes the
;;;;                            arguments in the wrong order.
;;;;
;;;; Both are invisible with one argument. BuildPath("C:\a", "b.txt") is therefore worth more
;;;; than any other check here: it has an exactly-known answer, and it gets it wrong in a
;;;; DIFFERENT way under each defect.

(in-package #:aion/windows/com/tests)

(def-suite live :description "A live COM round trip against Scripting.FileSystemObject." :in all)
(in-suite live)

(defmacro with-fso ((var) &body body)
  `(com:with-com-object (,var (com:create-object "Scripting.FileSystemObject"))
     ,@body))

(test a-live-com-object-can-be-created
  "CoCreateInstance against a real server, in the apartment, returning a live IDispatch."
  (with-fso (fso)
    (is-true (com:com-object-p fso))))

(test a-zero-argument-call-returns-a-string
  (with-fso (fso)
    (let ((name (com:invoke fso "GetTempName")))
      (is (stringp name) "GetTempName returned ~S" name)
      (is (plusp (length name))))))

(test a-one-argument-call-round-trips
  (with-fso (fso)
    (is (string-equal "bar" (com:invoke fso "GetBaseName" "C:\\foo\\bar.txt")))
    ;; FSO returns the extension WITHOUT the dot. Pinned as the server actually behaves:
    ;; the first draft of this test asserted ".txt" and the BINDING was right.
    (is (string-equal "txt" (com:invoke fso "GetExtensionName" "C:\\foo\\bar.txt")))))

(test a-two-argument-call-is-correct
  "THE CHECK THIS BINDING EXISTS TO PASS. A wrong VARIANT stride reads argument 2 as
garbage; a wrong rgvarg order returns the parts joined backwards. Both are visible here and
nowhere else in this suite."
  (with-fso (fso)
    (is (string= "C:\\a\\b.txt" (com:invoke fso "BuildPath" "C:\\a" "b.txt"))
        "BuildPath with two arguments returned the wrong result -- see this file's header")
    ;; A second, differently-shaped pair, so a coincidence cannot pass.
    (is (string= "X:\\one\\two\\three.dat"
                 (com:invoke fso "BuildPath" "X:\\one\\two" "three.dat")))))

(test argument-order-is-not-reversed
  "Stated separately from correctness because a REVERSED implementation still produces a
plausible string, and a test that only checked `a backslash appears' would pass it."
  (with-fso (fso)
    (let ((joined (com:invoke fso "BuildPath" "C:\\left" "right.txt")))
      (is (string= "C:\\left\\right.txt" joined))
      (is-false (string= "right.txt\\C:\\left" joined)
                "the arguments came back reversed -- rgvarg is being filled forwards"))))

(test a-boolean-result-marshals-as-variant-bool
  "VARIANT_TRUE is -1, not 1. A value read as `non-zero is true' handles both; one that
compares against 1 silently reports false for every true a server returns."
  (with-fso (fso)
    (is (eq t (com:invoke fso "FolderExists" "C:\\Windows")))
    (is (eq nil (com:invoke fso "FolderExists" "C:\\definitely-not-a-real-folder-9f3a")))))

(test a-three-argument-call-with-mixed-types
  "String, boolean, boolean -- and it has a side effect we can verify independently of the
return value, which a pure query cannot give us."
  (with-fso (fso)
    (com:with-com-object (dir (com:invoke fso "GetSpecialFolder" 2))   ; 2 = the temp folder
      (let* ((name (com:invoke fso "GetTempName"))
             (path (com:invoke fso "BuildPath" (com:invoke dir "Path") name)))
        (unwind-protect
             (progn
               ;; CreateTextFile(filename, overwrite, unicode)
               (com:with-com-object (stream (com:invoke fso "CreateTextFile" path t :false))
                 (com:invoke stream "WriteLine" "written by aion/windows/com")
                 (com:invoke stream "Close"))
               (is (eq t (com:invoke fso "FileExists" path))
                   "the three-argument CreateTextFile did not produce a file at ~S" path))
          (when (eq t (com:invoke fso "FileExists" path))
            (com:invoke fso "DeleteFile" path)))))))

(test a-call-returning-an-object-returns-a-com-object
  "VT_DISPATCH must arrive as a COM-OBJECT holding its OWN reference -- the pointer inside
the result VARIANT dies when that VARIANT is cleared."
  (with-fso (fso)
    (com:with-com-object (drives (com:invoke fso "Drives"))
      (is-true (com:com-object-p drives))
      (is (integerp (com:invoke drives "Count"))))))

(test an-unknown-member-is-named-not-a-bare-hresult
  (with-fso (fso)
    (signals com:unknown-member (com:invoke fso "NoSuchMethodAnywhere"))))

(test a-server-side-error-arrives-as-a-condition
  "DISP_E_EXCEPTION means the call reached the object and the object objected. A bare
0x80020009 tells a caller nothing, so the server's own words are preferred where it gives
them."
  (with-fso (fso)
    (handler-case
        (progn (com:invoke fso "GetFile" "Z:\\no\\such\\file\\at\\all.txt")
               (is-true nil "expected the server to raise"))
      (error (c)
        (is-true (plusp (length (princ-to-string c)))
                 "the condition printed nothing useful")))))

(test release-is-idempotent
  "Releasing twice would decrement a count that may already be zero, freeing an object
another holder still points at."
  (let ((fso (com:create-object "Scripting.FileSystemObject")))
    (is-true (com:release fso))
    (is-false (com:release fso) "the second release should be a no-op, not a decrement")))

(test a-real-server-date-converts-and-keeps-its-wall-clock
  "A live VT_DATE, end to end -- the case a consuming app hit on its first real database.

PINS THE TIMEZONE CONVENTION, which is the part that could drift silently. An OLE DATE is a
NAIVE local datetime carrying no zone, so none is invented: the value is returned as though
it were already UTC. The consequence, asserted here rather than left to a docstring: the
number decoded with ZONE 0 gives the wall clock the server meant, and decoding it in the
local zone would shift it.

The alternative -- converting local to UTC -- would make the same database cell read as a
different universal time on two machines in different zones, which for a stored date of birth
is inventing information the column never had."
  (let ((path (namestring (asdf:system-source-file :aion))))
    (with-fso (fso)
      (com:with-com-object (f (com:invoke fso "GetFile" (substitute #\\ #\/ path)))
        (let ((d (com:invoke f "DateLastModified")))
          (is (integerp d) "a VT_DATE should arrive as a universal time, got ~S" d)
          (is (> d 3000000000) "~D is not a plausible recent universal time" d)
          ;; The same file's time, read from Lisp rather than through COM. Compare the
          ;; two as WALL CLOCKS rather than by arithmetic on the zone offset -- decoding
          ;; the COM value at zone 0 and the Lisp value locally must give the same reading,
          ;; which is the convention stated without any DST arithmetic to get wrong.
          (multiple-value-bind (cs cm ch cd cmo cy) (decode-universal-time d 0)
            (multiple-value-bind (ls lm lh ld lmo ly) (decode-universal-time (file-write-date path))
              (is (equal (list cy cmo cd ch cm cs) (list ly lmo ld lh lm ls))
                  "COM read ~D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D at zone 0; FILE-WRITE-DATE reads ~D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D locally -- the convention moved"
                  cy cmo cd ch cm cs ly lmo ld lh lm ls))))))))
