;;;; pdfium-tests.lisp --- aion/pdfium against the fetched pdfium (#997).
;;;;
;;;; The PDFs are built here, a few hundred bytes each, so the tests need no fixture files. A PNG
;;;; that RENDER-PAGE returns is read back with chipz, which inflates its data independently of
;;;; the code that wrote it, and its pixels are compared with what the page draws.

(defpackage #:aion/pdfium/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:pdf #:aion/pdfium))
  (:export #:run-tests #:pdfium))

(in-package #:aion/pdfium/tests)

(def-suite pdfium :description "aion/pdfium: open a PDF, count its pages, render a page (#997).")
(in-suite pdfium)

(defun run-tests ()
  (let ((results (run 'pdfium)))
    (explain! results)
    (unless (results-status results)
      (error "aion/pdfium tests failed"))))

;;; --- a PDF built by hand ------------------------------------------------------------------

(defun %pdf (&key (pages 1) (content "0 0 0 rg 20 20 60 60 re f 1 0 0 rg 120 20 60 60 re f"))
  "A PDF of PAGES pages, each 200 by 100 points, drawing CONTENT: by default a black square at
x 20-80 and a red one at x 120-180, both from y 20 to 80 (PDF's y runs up from the bottom)."
  (let ((objects '()) (n 0))
    (flet ((add (text) (push text objects) (incf n)))
      (add "<< /Type /Catalog /Pages 2 0 R >>")
      (add (format nil "<< /Type /Pages /Kids [~{~D 0 R~^ ~}] /Count ~D >>"
                   (loop for i below pages collect (+ 3 (* 2 i))) pages))
      (dotimes (i pages)
        (add (format nil "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents ~D 0 R >>"
                     (+ 4 (* 2 i))))
        (add (format nil "<< /Length ~D >>~%stream~%~A~%endstream" (length content) content))))
    (let* ((out (make-string-output-stream))
           (offsets '()))
      (write-string (format nil "%PDF-1.4~%") out)
      (loop for text in (reverse objects) for i from 1
            do (push (length (get-output-stream-string-copy out)) offsets)
               (format out "~D 0 obj~%~A~%endobj~%" i text))
      (let ((xref (length (get-output-stream-string-copy out))))
        (format out "xref~%0 ~D~%0000000000 65535 f ~%" (1+ n))
        (dolist (o (reverse offsets)) (format out "~10,'0D 00000 n ~%" o))
        (format out "trailer~%<< /Size ~D /Root 1 0 R >>~%startxref~%~D~%%%EOF~%" (1+ n) xref))
      (map '(vector (unsigned-byte 8)) #'char-code (get-output-stream-string out)))))

(defun get-output-stream-string-copy (stream)
  "STREAM's text so far, without emptying it."
  (let ((text (get-output-stream-string stream)))
    (write-string text stream)
    text))

;;; --- reading a PNG back -------------------------------------------------------------------

(defun %u32 (v i) (logior (ash (aref v i) 24) (ash (aref v (+ i 1)) 16) (ash (aref v (+ i 2)) 8) (aref v (+ i 3))))

(defun %read-png (png)
  "(values PIXELS WIDTH HEIGHT CHANNELS) of PNG, inflated with chipz. Only what RENDER-PAGE
writes: 8 bits, grey or RGB, filter None."
  (assert (equalp (subseq png 0 8) #(137 80 78 71 13 10 26 10)))
  (let ((at 8) width height channels (idat (make-array 0 :element-type '(unsigned-byte 8)
                                                          :adjustable t :fill-pointer 0)))
    (loop
      (let* ((length (%u32 png at))
             (type (map 'string #'code-char (subseq png (+ at 4) (+ at 8))))
             (data (subseq png (+ at 8) (+ at 8 length))))
        (cond ((string= type "IHDR")
               (setf width (%u32 data 0) height (%u32 data 4)
                     channels (ecase (aref data 9) (0 1) (2 3))))
              ((string= type "IDAT") (loop for b across data do (vector-push-extend b idat)))
              ((string= type "IEND") (return)))
        (incf at (+ 12 length))))
    (let* ((raw (chipz:decompress nil 'chipz:zlib (coerce idat '(simple-array (unsigned-byte 8) (*)))))
           (row (1+ (* width channels)))
           (pixels (make-array (* width height channels) :element-type '(unsigned-byte 8))))
      (assert (= (length raw) (* height row)))
      (dotimes (y height)
        (assert (zerop (aref raw (* y row))))   ; filter None
        (replace pixels raw :start1 (* y width channels) :start2 (1+ (* y row)) :end2 (* (1+ y) row)))
      (values pixels width height channels))))

(defun %pixel (pixels width channels x y)
  (let ((at (* channels (+ x (* y width)))))
    (coerce (subseq pixels at (+ at channels)) 'list)))

;;; --- the tests ----------------------------------------------------------------------------

(test the-library-loads-from-the-fetched-copy
  (is (stringp (pdf:ensure-loaded)))
  (is-true (pdf:pdfium-loaded-p))
  (is (search "pdfium" (string-downcase (pdf:pdfium-path)))))

(test a-page-renders-grey-at-the-size-its-dpi-gives
  (pdf:with-pdf (doc (%pdf))
    (is (= 1 (pdf:page-count doc)))
    (multiple-value-bind (png width height) (pdf:render-page doc 0 :dpi 72)
      (is (= 200 width)) (is (= 100 height))
      (multiple-value-bind (pixels w h channels) (%read-png png)
        (is (= 200 w)) (is (= 100 h)) (is (= 1 channels) "grey by default")
        (is (< (first (%pixel pixels w 1 50 50)) 40) "inside the black square: dark")
        (is (> (first (%pixel pixels w 1 100 50)) 215) "between the squares: white")
        (is (> (first (%pixel pixels w 1 50 5)) 215) "above the squares: white")))
    (multiple-value-bind (png width height) (pdf:render-page doc 0 :dpi 144)
      (declare (ignore png))
      (is (= 400 width) "twice the DPI, twice the width") (is (= 200 height)))))

(test a-page-renders-in-colour-when-asked
  (pdf:with-pdf (doc (%pdf))
    (multiple-value-bind (pixels w h channels) (%read-png (pdf:render-page doc 0 :dpi 72 :color t))
      (declare (ignore h))
      (is (= 3 channels))
      (destructuring-bind (r g b) (%pixel pixels w 3 150 50)
        (is (and (> r 215) (< g 40) (< b 40)) "inside the red square: red, got ~A ~A ~A" r g b))
      (destructuring-bind (r g b) (%pixel pixels w 3 50 50)
        (is (and (< r 40) (< g 40) (< b 40)) "inside the black square: black, got ~A ~A ~A" r g b)))))

(test pages-are-counted-and-each-renders
  (pdf:with-pdf (doc (%pdf :pages 3))
    (is (= 3 (pdf:page-count doc)))
    (is (every #'plusp (loop for i below 3 collect (length (pdf:render-page doc i :dpi 36)))))))

(defun %refusal (thunk)
  (handler-case (progn (funcall thunk) nil)
    (pdf:pdf-refused (c) (pdf:pdf-refused-reason c))))

(test what-is-not-a-readable-pdf-is-refused-with-its-reason
  (is (eq :format (%refusal (lambda () (pdf:open-pdf (map '(vector (unsigned-byte 8)) #'char-code "not a pdf at all"))))))
  (is (eq :empty (%refusal (lambda () (pdf:open-pdf (make-array 0 :element-type '(unsigned-byte 8)))))))
  (is (eq :source (%refusal (lambda () (pdf:open-pdf 42))))))

(test each-limit-is-checked-before-pdfium-is-asked
  (is (eq :too-large (%refusal (lambda () (let ((pdf:*max-pdf-bytes* 100)) (pdf:open-pdf (%pdf)))))))
  (is (eq :too-many-pages (%refusal (lambda () (let ((pdf:*max-pdf-pages* 2)) (pdf:open-pdf (%pdf :pages 3)))))))
  (pdf:with-pdf (doc (%pdf))
    (is (eq :too-many-pixels (%refusal (lambda () (let ((pdf:*max-render-pixels* 100))
                                                    (pdf:render-page doc 0 :dpi 72))))))
    (is (eq :dpi (%refusal (lambda () (pdf:render-page doc 0 :dpi 0)))))
    (is (eq :dpi (%refusal (lambda () (pdf:render-page doc 0 :dpi 1201)))))
    (is (eq :page (%refusal (lambda () (pdf:render-page doc 1)))))
    (is (eq :page (%refusal (lambda () (pdf:render-page doc -1))))))
  (let ((doc (pdf:open-pdf (%pdf))))
    (pdf:close-pdf doc)
    (pdf:close-pdf doc)
    (is (eq :closed (%refusal (lambda () (pdf:page-count doc)))) "a closed document is refused")))

(test a-report-names-the-limit-and-not-the-content
  (let ((c (handler-case (let ((pdf:*max-pdf-bytes* 100)) (pdf:open-pdf (%pdf)) nil)
             (pdf:pdf-refused (c) c))))
    (is (search "*MAX-PDF-BYTES*" (princ-to-string c)) "~A" c)
    (is (null (search "MediaBox" (princ-to-string c))))))

(test a-pdf-opens-from-a-file-too
  (let ((path (uiop:with-temporary-file (:pathname p :type "pdf" :keep t)
                p)))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
             (write-sequence (%pdf :pages 2) out))
           (pdf:with-pdf (doc path) (is (= 2 (pdf:page-count doc)))))
      (ignore-errors (delete-file path)))))

(test the-not-found-report-says-how-to-fetch-it
  (let ((report (princ-to-string (make-condition 'pdf:pdfium-not-found :searched '("a" "b")))))
    (is (search "scripts/fetch-pdfium.lisp" report))
    (is (search "AION_PDFIUM_LIBRARY" report))))
