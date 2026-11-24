;;;; packages.lisp --- the package of dokimasia/mnemosyne (#1028, dokimasia ADR-0001).

(cl:defpackage #:dokimasia/mnemosyne
  (:use #:cl)
  (:local-nicknames (#:d #:dokimasia)
                    (#:conn #:mnemosyne/conn)
                    (#:query #:mnemosyne/query)
                    (#:fldsh #:mnemosyne/field-shell)
                    (#:param #:mnemosyne/param))
  (:documentation "Stored-data probes for dokimasia's :EXPECT-STORED step that read the app's
database through mnemosyne (#1028). See dokimasia/README.md, \"Probes\".")
  (:export #:define-row-probe #:define-query-probe))
