;;;; multipart-tests.lisp --- multipart/form-data (pre-publication issue 143).
;;;;
;;;; Two things here are worth more than the happy path, and both are why this belongs in
;;;; the framework rather than in each app:
;;;;
;;;;   - CHUNK-SIZE 1. A boundary straddling a read boundary is the bug every hand-rolled
;;;;     multipart parser has, and it is invisible at any realistic chunk size because the
;;;;     delimiter happens to land inside one read. Forcing one byte per read makes every
;;;;     delimiter straddle, so the hold-back window is exercised on every test that uses it.
;;;;   - The hostile filenames. `../../etc/passwd`, a Windows device name, a NUL byte and a
;;;;     trailing dot are all things a client can send today, and the sanitised form is what
;;;;     an app will reach for.

(in-package #:hyperion/tests)

(def-suite multipart :description "multipart/form-data parsing, ceilings, filenames." :in hyperion)
(in-suite multipart)

(defparameter +crlf+ (format nil "~C~C" #\Return #\Newline))

(defun %mp-body (boundary parts)
  "Build a multipart body. Each part is (name value &key filename content-type), where
VALUE is a string or an octet vector."
  (with-output-to-string (s)
    (dolist (p parts)
      (destructuring-bind (name value &key filename content-type) p
        (format s "--~A~A" boundary +crlf+)
        (format s "Content-Disposition: form-data; name=\"~A\"~@[; filename=\"~A\"~]~A"
                name filename +crlf+)
        (when content-type (format s "Content-Type: ~A~A" content-type +crlf+))
        (format s "~A" +crlf+)
        (write-string (if (stringp value)
                          value
                          (sb-ext:octets-to-string value :external-format :latin-1))
                      s)
        (format s "~A" +crlf+)))
    (format s "--~A--~A" boundary +crlf+)))

(defun %mp-env (body &key (boundary "BOUND") (external-format :utf-8))
  "A Clack env whose :raw-body is an octet stream over BODY (a string).
Backed by a temp file so it is a real stream, read once, exactly like a socket."
  (let* ((octets (sb-ext:string-to-octets body :external-format external-format))
         (path (uiop:tmpize-pathname (merge-pathnames "hyperion-mp-test"
                                                      (uiop:temporary-directory)))))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence octets out))
    (values (list :content-type (format nil "multipart/form-data; boundary=~A" boundary)
                  :raw-body (open path :element-type '(unsigned-byte 8))
                  :content-length (length octets))
            path)))

(defmacro %with-parts ((var body &rest options) &body forms)
  "Parse BODY into VAR, run FORMS, and always delete any temp files the parse produced."
  `(let ((,var nil))
     (unwind-protect
          (progn (setf ,var (http:parse-multipart (%mp-env ,body) ,@options))
                 ,@forms)
       (when ,var (http:delete-parts ,var)))))

;;; --- detection -------------------------------------------------------------

(test multipart-p-needs-both-the-type-and-a-boundary
  (is (http:multipart-p (list :content-type "multipart/form-data; boundary=abc")))
  (is (http:multipart-p (list :content-type "MULTIPART/FORM-DATA; BOUNDARY=abc")))
  ;; a type with no boundary is not parseable and must not claim to be
  (is (not (http:multipart-p (list :content-type "multipart/form-data"))))
  (is (not (http:multipart-p (list :content-type "application/x-www-form-urlencoded"))))
  (is (not (http:multipart-p (list)))))

;;; --- ordinary fields, and the straddling delimiter -------------------------

(test plain-fields-parse
  (%with-parts (parts (%mp-body "BOUND" '(("a" "1") ("b" "two"))))
    (is (= 2 (length parts)))
    (is (string= "a" (http:part-name (first parts))))
    (is (string= "1" (http:part-text (first parts))))
    (is (string= "two" (http:multipart-param parts "b")))
    ;; a plain field is not a file, whatever else is true of it
    (is (not (http:part-file-p (first parts))))
    (is (null (http:part-filename (first parts))))))

(test a-delimiter-straddling-every-read-still-parses
  ;; chunk-size 1 makes every delimiter cross a read boundary. This is the hold-back
  ;; window under test; at the default chunk size the whole delimiter lands in one read
  ;; and the bug this guards against cannot appear.
  (%with-parts (parts (%mp-body "BOUND" '(("a" "hello") ("b" "world")))
                      :chunk-size 1)
    (is (= 2 (length parts)))
    (is (string= "hello" (http:multipart-param parts "a")))
    (is (string= "world" (http:multipart-param parts "b")))))

(test content-that-merely-resembles-the-boundary-is-content
  ;; A value containing the boundary text without the CRLF-- prefix must not end the part.
  (%with-parts (parts (%mp-body "BOUND" '(("a" "x BOUND y") ("b" "-BOUND")))
                      :chunk-size 1)
    (is (string= "x BOUND y" (http:multipart-param parts "a")))
    (is (string= "-BOUND" (http:multipart-param parts "b")))))

(test an-empty-field-is-a-field
  (%with-parts (parts (%mp-body "BOUND" '(("a" "") ("b" "v"))))
    (is (= 2 (length parts)))
    (is (string= "" (http:multipart-param parts "a")))
    (is (= 0 (http:part-size (first parts))))))

(test repeated-names-are-all-returned
  ;; <input type=file multiple> and repeated fields post the same name more than once --
  ;; the same trap pre-publication issue 136 fixed for urlencoded bodies.
  (%with-parts (parts (%mp-body "BOUND" '(("tag" "a") ("tag" "b") ("tag" "c"))))
    (is (= 3 (length (http:find-parts parts "tag"))))
    (is (equal '("a" "b" "c") (mapcar #'http:part-text (http:find-parts parts "tag"))))
    (is (string= "a" (http:part-text (http:find-part parts "tag"))))
    (is (null (http:find-part parts "absent")))))

;;; --- files -----------------------------------------------------------------

(test a-file-part-carries-its-filename-and-claimed-type
  (%with-parts (parts (%mp-body "BOUND"
                                '(("doc" "hello" :filename "notes.txt"
                                         :content-type "text/plain"))))
    (let ((p (http:find-part parts "doc")))
      (is (http:part-file-p p))
      (is (string= "notes.txt" (http:part-filename p)))
      (is (string= "notes.txt" (http:part-safe-filename p)))
      (is (string= "text/plain" (http:part-content-type p)))
      (is (string= "hello" (http:part-text p)))
      (is (= 5 (http:part-size p))))))

(test binary-content-survives-intact
  ;; The original complaint: decoding as UTF-8 corrupts bytes before parsing can start.
  (let* ((bytes (make-array 256 :element-type '(unsigned-byte 8)))
         (body (progn (dotimes (i 256) (setf (aref bytes i) i))
                      (%mp-body "BOUND" (list (list "f" bytes :filename "raw.bin"))))))
    (let ((parts (http:parse-multipart (%mp-env body :external-format :latin-1))))
      (unwind-protect
           (let ((p (http:find-part parts "f")))
             (is (= 256 (http:part-size p)))
             (is (equalp bytes (http:part-bytes p))))
        (http:delete-parts parts)))))

(test a-large-part-spills-to-disk-and-a-small-one-does-not
  (let ((big (make-string 4096 :initial-element #\x)))
    (%with-parts (parts (%mp-body "BOUND" (list (list "small" "tiny")
                                                (list "big" big :filename "big.txt")))
                        :memory-threshold 100)
      (let ((s (http:find-part parts "small"))
            (b (http:find-part parts "big")))
        (is (not (null (http:part-bytes s))) "a small part stays in memory")
        (is (null (http:part-path s)))
        (is (null (http:part-bytes b)) "a large part must not also be held in memory")
        (is (not (null (http:part-path b))) "a large part spills to a file")
        (is (probe-file (http:part-path b)))
        (is (= 4096 (http:part-size b)))
        ;; and it reads back byte-for-byte through the same accessor
        (is (string= big (http:part-text b)))))))

(test delete-parts-removes-the-spilled-files
  (let* ((big (make-string 2048 :initial-element #\y))
         (parts (http:parse-multipart (%mp-env (%mp-body "BOUND" (list (list "f" big))))
                                      :memory-threshold 10))
         (path (http:part-path (first parts))))
    (is (not (null path)) "the part should have spilled")
    (is (probe-file path))
    (http:delete-parts parts)
    (is (not (probe-file path)) "the temp file must be gone")
    (is (null (http:part-path (first parts))) "and the part must stop pointing at it")))

;;; --- the ceilings, which are on by default ---------------------------------

(test a-body-over-the-size-ceiling-is-refused
  (let ((body (%mp-body "BOUND" (list (list "f" (make-string 5000 :initial-element #\z))))))
    (signals http:multipart-too-large
      (http:parse-multipart (%mp-env body) :max-size 1000))))

(test too-many-parts-is-refused-even-when-every-part-is-tiny
  ;; The other shape of the same attack: a thousand one-byte parts stays under any byte
  ;; ceiling and exhausts the same resources.
  (let ((body (%mp-body "BOUND" (loop for i below 20 collect (list (format nil "f~D" i) "x")))))
    (signals http:multipart-too-many-parts
      (http:parse-multipart (%mp-env body) :max-parts 5))))

(test the-ceilings-are-on-without-being-asked-for
  ;; A limit an app must remember to set is not set on the day it matters.
  (is (plusp http:*max-body-size*))
  (is (plusp http:*max-parts*))
  (is (plusp http:*memory-threshold*)))

(test a-failed-parse-leaves-no-temp-files-behind
  ;; The error path, which is the one that leaks: a truncated upload that already spilled
  ;; must not orphan its file. A temp file per failed upload is a slow disk-fill nobody
  ;; attributes to uploads.
  (let* ((before (length (directory (merge-pathnames "hyperion-upload*"
                                                     (uiop:temporary-directory)))))
         (truncated (concatenate 'string
                                 "--BOUND" +crlf+
                                 "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\""
                                 +crlf+ +crlf+
                                 (make-string 3000 :initial-element #\q))))  ; no closing boundary
    (signals http:multipart-error
      (http:parse-multipart (%mp-env truncated) :memory-threshold 10))
    (is (= before (length (directory (merge-pathnames "hyperion-upload*"
                                                      (uiop:temporary-directory)))))
        "a failed parse must delete whatever it spilled")))

(test malformed-bodies-signal-rather-than-returning-nonsense
  (signals http:multipart-error
    (http:parse-multipart (list :content-type "multipart/form-data" :raw-body nil)))
  (signals http:multipart-error
    (http:parse-multipart (%mp-env "not multipart at all"))))

;;; --- filenames are attacker-controlled -------------------------------------

(test sanitize-filename-strips-paths-and-traversal
  (is (string= "passwd" (http:sanitize-filename "../../etc/passwd")))
  (is (string= "x.txt" (http:sanitize-filename "/absolute/x.txt")))
  (is (string= "x.txt" (http:sanitize-filename "C:\\windows\\x.txt")))
  (is (string= "x.txt" (http:sanitize-filename "a/b\\c/x.txt")))
  (is (null (http:sanitize-filename "..")))
  (is (null (http:sanitize-filename ".")))
  (is (null (http:sanitize-filename "")))
  (is (null (http:sanitize-filename nil))))

(test sanitize-filename-handles-the-windows-traps
  ;; Windows strips trailing dots and spaces AFTER your check runs, so "evil.exe. " and
  ;; "evil.exe" are the same file to the filesystem and different strings to a validator.
  (is (string= "evil.exe" (http:sanitize-filename "evil.exe. ")))
  (is (string= "evil.exe" (http:sanitize-filename "evil.exe...")))
  ;; device names resolve before the directory is consulted
  (is (string= "_con" (http:sanitize-filename "con")))
  (is (string= "_CON.txt" (http:sanitize-filename "CON.txt")))
  (is (string= "_lpt1" (http:sanitize-filename "lpt1"))))

(test sanitize-filename-removes-control-bytes
  ;; A NUL truncates a path in C; the rest confuse logs and terminals.
  (is (string= "ab" (http:sanitize-filename (format nil "a~Cb" (code-char 0)))))
  (is (string= "ab" (http:sanitize-filename (format nil "a~Cb" (code-char 13))))))

(test both-the-raw-and-the-sanitised-filename-are-available
  ;; Both, deliberately: apps reach for whatever is nearest, so the nearest must be safe
  ;; and the raw one must be clearly labelled rather than absent.
  (%with-parts (parts (%mp-body "BOUND" '(("f" "x" :filename "../../etc/passwd"))))
    (let ((p (http:find-part parts "f")))
      (is (string= "../../etc/passwd" (http:part-filename p)) "the raw value is preserved")
      (is (string= "passwd" (http:part-safe-filename p)) "and a safe one is offered"))))

(test a-claimed-content-type-is-only-a-claim
  ;; Pinned as documentation: the value is echoed back untouched, and an app that treats
  ;; it as evidence of file type has an upload vulnerability.
  (%with-parts (parts (%mp-body "BOUND" '(("f" "MZ..." :filename "totally.png"
                                               :content-type "image/png"))))
    (is (string= "image/png" (http:part-content-type (http:find-part parts "f"))))))

;;; --- the urlencoded readers keep their behaviour ----------------------------

(test form-param-still-does-not-see-multipart
  ;; Documented rather than fixed: a multipart body yields nothing to the urlencoded
  ;; readers, which reads exactly like "the field was absent".
  (let ((body (%mp-body "BOUND" '(("a" "1")))))
    (is (null (http:form-param body "a")))
    (is (null (http:form-params body "a")))))
