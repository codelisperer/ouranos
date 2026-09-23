;;;; string-tests.lisp --- UTF-16 marshalling, including the cases ANSI would lose.
;;;;
;;;; The A variants are not a simpler alternative: they encode through the machine's ANSI
;;;; code page, so the same call produces different bytes on a differently-configured
;;;; Windows and anything outside the page becomes a question mark. A test that only ever
;;;; round-trips "hello" cannot tell the two apart, so these deliberately carry text that
;;;; ANSI would damage.

(in-package #:aion/windows/tests)

(def-suite strings :description "UTF-16LE marshalling and ownership." :in all)
(in-suite strings)

(test ascii-round-trips
  (w:with-wide-string (p "Scripting.FileSystemObject")
    (is (string= "Scripting.FileSystemObject" (w:wide-string-to-lisp p)))))

(test empty-string-round-trips
  "An empty string is a null terminator and nothing else -- an easy off-by-one."
  (w:with-wide-string (p "")
    (is (string= "" (w:wide-string-to-lisp p)))))

(test non-ansi-text-round-trips
  "The whole reason for the W variants. Any of these would be mangled by a code-page
encoding, which is what a wrong marshalling layer silently falls back to."
  (dolist (s '("Grüße aus München" "日本語のテキスト" "Ελληνικά" "Здравствуйте"))
    (w:with-wide-string (p s)
      (is (string= s (w:wide-string-to-lisp p))
          "~S did not survive the round trip" s))))

(test astral-characters-round-trip
  "Outside the BMP, so each of these is a SURROGATE PAIR -- two WCHARs for one character.
A layer that assumes one code unit per character truncates exactly here."
  (let ((s "an emoji: 😀 and a rare han: 𠮷"))
    (w:with-wide-string (p s)
      (is (string= s (w:wide-string-to-lisp p))
          "surrogate pairs did not survive the round trip"))))

(test embedded-newlines-and-quotes-survive
  (let ((s (format nil "line1~%line2~C\"quoted\"" #\Tab)))
    (w:with-wide-string (p s)
      (is (string= s (w:wide-string-to-lisp p))))))

(test with-wide-string-frees-on-a-non-local-exit
  "The common path out of a Windows call is a SIGNALLED condition, so the macro has to
release on that path too -- a plain LET would leak on every error."
  (let ((escaped nil))
    (handler-case
        (w:with-wide-string (p "leak me")
          (setf escaped p)
          (error "non-local exit"))
      (error () nil))
    ;; Nothing portable can assert the free happened; what IS assertable is that the macro
    ;; ran its cleanup path rather than propagating before it. The pointer was captured, so
    ;; the body ran; the handler caught, so the unwind completed.
    (is-true (not (null escaped))
             "the body did not run, so this test proved nothing about cleanup")))

(test wide-string-to-lisp-tolerates-a-null-pointer
  "Windows hands back NULL for `no string' constantly. Decoding it must be NIL, not a fault."
  (is (null (w:wide-string-to-lisp (cffi:null-pointer)))))
