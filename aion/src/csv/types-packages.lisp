;;;; types-packages.lisp --- the package for aion/csv's typed core.
;;;;
;;;; Separate from src/csv/packages.lisp because that file belongs to the dependency-free
;;;; system: it must load on an implementation with no Coalton, so it cannot :use Coalton
;;;; or name a Coalton package. This one is only loaded by the opt-in aion/csv/types.

(cl:defpackage #:aion/csv/types
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:lst #:coalton-library/list))
  (:documentation
   "The typed core of aion/csv: the reader's four states, the eight character classes a
    dialect sorts characters into, and a TOTAL transition between them -- the state machine
    that aion/csv/parse.lisp spells as an ECASE and a chain of CONDs, made a type the
    compiler checks. Also a Dialect whose special characters are provably distinct, which
    the CL DEFSTRUCT cannot express.

    OPT-IN BY DESIGN: aion/csv does not depend on this and never will, because it is
    dependency-free so the portable backend loads on bare SBCL/CCL/ECL/ABCL with no Coalton
    compile. What stops the types being decorative is PARSE -- a complete reference parser
    built from the transition -- and the conformance test that requires the shipping parser
    to agree with it.")
  (:export #:CharClass #:ClDelimiter #:ClQuote #:ClEscape #:ClComment
           #:ClNewline #:ClReturn #:ClOther #:ClEof #:char-class->string
           #:ParseState #:StStart #:StUnquoted #:StQuoted #:StQuoteEnd #:parse-state->string
           #:Action #:AcNothing #:AcAdd #:AcAddQuote #:AcTakeEscaped #:AcEmitField
           #:AcFinishRow #:AcSkipLine #:AcEndInput #:AcFail #:action->string
           #:Step #:transition #:step-action #:step-next
           #:Dialect #:dialect-delimiter #:dialect-quote #:dialect-escape
           #:dialect-comment #:dialect-skip-blank? #:dialect-ok? #:classify
           #:rfc4180 #:tsv #:parse
           ;; the CL boundary: promised representations only
           #:step-names #:state-names #:class-names
           #:dialect-chars-ok? #:parse-rfc4180-rows #:parse-rfc4180-ok?))
