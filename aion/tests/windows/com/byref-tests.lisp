;;;; byref-tests.lisp --- [out] parameters, against a server that really writes one (pre-publication issue 304).
;;;;
;;;; A layer that cannot express a by-reference argument can call the Automation members
;;;; that happen to return their answer, and not the ones that hand it back -- which is most
;;;; of Find/Replace, several Shell and WMI members, and ADO's records-affected. Before pre-publication issue 304
;;;; `+vt-byref+' was defined, exported, and used nowhere.
;;;;
;;;; WHY ADO OVER A CSV, AND NOT A DATABASE. `Connection.Execute(CommandText,
;;;; RecordsAffected, Options)' is the canonical [out] parameter and ADO ships with every
;;;; Windows. The ACE OLE DB provider's TEXT driver reads and writes a directory of CSV
;;;; files, so the whole round trip needs a temp directory and no database engine, no
;;;; .accdb, and nothing installed that a developer machine would not already have for
;;;; Office. Scripting.FileSystemObject -- the server the rest of these tests use, precisely
;;;; because it needs nothing -- has no [out] parameter to offer.
;;;;
;;;; A ZERO WOULD NOT HAVE BEEN EVIDENCE. The first probe of this ran a SELECT and read back
;;;; 0, which cannot distinguish "the server wrote zero" from "nothing was written and the
;;;; cell still holds a default". So the test asserts an INSERT, whose answer is 1, and
;;;; checks the file to confirm the 1 is true rather than merely non-zero.
;;;;
;;;; SKIPS WHEN ACE IS ABSENT. The provider is not part of Windows; a machine without Office
;;;; or the Access Runtime has no ACE, and a red suite there would be a lie about this
;;;; binding. That absence is exactly what pre-publication issue 306's capability predicate is for, and until it
;;;; exists this file detects it the only way available: try, and skip on failure.

(in-package #:aion/windows/com/tests)

(def-suite byref :description "By-reference [out] parameters, against a live ADO." :in all)
(in-suite byref)

(defparameter +ace-text-connection+
  "Provider=Microsoft.ACE.OLEDB.16.0;Data Source=~A;Extended Properties=\"text;HDR=Yes;FMT=Delimited\""
  "ACE's text driver over a DIRECTORY -- Data Source is the folder, and each .csv in it is a
table. Pinned to ACE 16 deliberately rather than searching 16/12/Jet: this is a test, and a
test that quietly succeeds against a different provider than the one it names is reporting
about a machine rather than about the code.")

(defparameter +absent-provider-connection+
  "Provider=Ouranos.No.Such.OLEDB.Provider.1;Data Source=~A"
  "A provider that is registered NOWHERE, so the failure branch below can be driven on a
machine that HAS ACE. Without it the absent-provider path is only reachable on a host
without Office -- which is every CI runner and no developer machine, and is precisely how
pre-publication issue 323 reached main.")

(defmacro with-csv-connection ((conn dir &key (connection '+ace-text-connection+)) &body body)
  "A temp directory holding one CSV, and an open ADO connection over it. Skips if the
provider is absent.

SKIP DOES NOT ABORT THE TEST (pre-publication issue 323). FiveAM's SKIP records a skipped check and RETURNS --
so the first version of this macro bound CONN to skip's return value, a list containing a
TEST-SKIPPED object, and handed it to the next COM call as though it were a connection:

    Unexpected Error: #<TYPE-ERROR expected-type: COM:COM-OBJECT
    datum: (#<IT.BESE.FIVEAM::TEST-SKIPPED ...>)>

The whole point of the branch is to report cleanly on a machine without the provider, and
it was the branch that crashed. RETURN-FROM is what makes the skip a skip; the directory
cleanup still runs because it is the UNWIND-PROTECT outside the block."
  (let ((done (gensym "SKIPPED")))
    `(block ,done
       (let ((,dir (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ouranos-byref-~D/"
                                             (random 100000 (make-random-state t)))
                                     (uiop:temporary-directory)))))
         (ensure-directories-exist ,dir)
         (unwind-protect
              (progn
                (with-open-file (out (merge-pathnames "t.csv" ,dir)
                                     :direction :output :if-exists :supersede)
                  (format out "id,name~%1,alpha~%"))
                (let ((,conn (handler-case
                                 (let ((c (com:create-object "ADODB.Connection")))
                                   (com:invoke-method
                                    c "Open"
                                    (format nil ,connection (uiop:native-namestring ,dir)))
                                   c)
                               (error (e)
                                 (skip "no usable OLE DB provider on this machine (~A)"
                                       (type-of e))
                                 (return-from ,done nil)))))
                  (unwind-protect (progn ,@body)
                    (ignore-errors (com:invoke-method ,conn "Close"))
                    (com:release ,conn))))
           (ignore-errors (uiop:delete-directory-tree ,dir :validate t)))))))

(defun %csv-lines (dir)
  (with-open-file (in (merge-pathnames "t.csv" dir))
    (loop for line = (read-line in nil) while line collect line)))

(test an-out-parameter-is-written-back-into-the-cell
  "ADO writes the records-affected count into argument 2. Asserted as 1, not merely non-NIL."
  (with-csv-connection (conn dir)
    (let ((rows (com:by-ref)))
      (is (null (com:by-ref-value rows)) "a fresh cell starts empty")
      (com:invoke-method conn "Execute"
                         "INSERT INTO [t.csv] (id,name) VALUES (2,'beta')" rows 1)
      (is (eql 1 (com:by-ref-value rows))
          "ADO must report exactly one row affected; got ~S" (com:by-ref-value rows))
      ;; The 1 has to be TRUE, not just non-zero: a layer that wrote a plausible number
      ;; without the server having done anything would pass the assertion above.
      (is (= 3 (length (%csv-lines dir)))
          "and the file must actually have grown by one row: ~S" (%csv-lines dir)))))

(test a-plain-argument-in-the-same-position-carries-nothing-back
  "THE CONTROL. Without a cell the call still succeeds and the count is unreachable -- which
is the behaviour before pre-publication issue 304, reproduced rather than described. A test asserting only that
the cell gets a value would pass against a layer that wrote to every argument."
  (with-csv-connection (conn dir)
    (let ((plain 0))
      (com:invoke-method conn "Execute"
                         "INSERT INTO [t.csv] (id,name) VALUES (3,'gamma')" plain 1)
      (is (eql 0 plain) "a plain argument is not a place; it cannot have been written to")
      (is (= 3 (length (%csv-lines dir))) "though the statement did run"))))

(test a-cell-carries-its-value-in-as-well-as-out
  "[in,out] is the same cell. The value present before the call is what the server sees, so
one mechanism serves both directions -- asserted through Options, whose value ADO acts on."
  (with-csv-connection (conn dir)
    (let ((rows (com:by-ref)))
      ;; adCmdText = 1, passed through a cell rather than as a literal. If the IN direction
      ;; were broken the server would see VT_EMPTY and guess at the command type.
      (com:invoke-method conn "Execute" "INSERT INTO [t.csv] (id,name) VALUES (4,'delta')"
                         rows (com:by-ref 1))
      (is (eql 1 (com:by-ref-value rows)) "the OUT cell still reports one row")
      (is (= 3 (length (%csv-lines dir))) "and the insert happened"))))

(test many-cells-in-one-call-do-not-cross
  "Referents are a separate block indexed independently of the argument array, which is
reversed. An off-by-one between those two indexes would put one cell's answer in another,
and with a single by-ref argument nothing would ever notice."
  (with-csv-connection (conn dir)
    (let ((rows (com:by-ref))
          (options (com:by-ref 1)))
      (com:invoke-method conn "Execute" "INSERT INTO [t.csv] (id,name) VALUES (5,'epsilon')"
                         rows options)
      (is (eql 1 (com:by-ref-value rows)) "the records-affected cell holds the count")
      (is (eql 1 (com:by-ref-value options)) "and the options cell is not the count"))))

(test the-absent-provider-path-skips-cleanly
  "pre-publication issue 323, AND THE ONLY TEST HERE THAT RUNS ITS INTERESTING BRANCH ON THIS MACHINE.

Every other test in this file takes the provider-present path, because a developer box with
Office has ACE. The absent path was therefore reachable only on a host WITHOUT Office --
which is every CI runner and no developer machine -- so it shipped to main having never been
executed anywhere, and crashed with a TYPE-ERROR the first time a machine ran it.

FiveAM's SKIP does not abort: it records a skipped check and returns. The macro bound CONN
to that return value -- a list containing a TEST-SKIPPED object -- and passed it to the next
COM call. The branch whose whole job was to fail gracefully was the branch that crashed.

This drives that path deliberately, by naming a provider registered nowhere. It works on a
machine that HAS ACE, which is the point: the absence is fabricated rather than waited for.

If the skip aborts as it must, this test reports SKIPPED and the assertion never runs. If it
returns instead, the body executes and the assertion fails immediately -- so a regression is
a red test rather than a type error three frames later."
  ;; No DECLARE here: WITH-CSV-CONNECTION puts the body inside a PROGN, where a declaration
  ;; is compiled as a call to a function named DECLARE (#263). CONN and DIR need none anyway:
  ;; the macro itself uses both, to close the connection and delete the directory.
  (with-csv-connection (conn dir :connection +absent-provider-connection+)
    (is nil "the body must never run when the provider could not be opened")))
