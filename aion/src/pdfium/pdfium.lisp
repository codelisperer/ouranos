;;;; pdfium.lisp --- open a PDF, count its pages, render a page to a PNG (#997).
;;;;
;;;;     (with-pdf (doc #p"cards.pdf")
;;;;       (loop for i below (page-count doc)
;;;;             collect (render-page doc i :dpi 200)))      ; a list of PNG octet vectors
;;;;
;;;; LIMITS. A PDF is outside input, and pdfium allocates what a file asks it to, so each step
;;;; is bounded before pdfium sees it: the file's size (*MAX-PDF-BYTES*), its page count
;;;; (*MAX-PDF-PAGES*), and a rendered page's pixels (*MAX-RENDER-PIXELS*), checked from the
;;;; page's size and the DPI before a bitmap is made. Each refusal is PDF-REFUSED, with a reason
;;;; keyword and a sentence that names the limit and never the file's content.
;;;;
;;;; THE PNG is written here, with no compression: the image data goes into stored deflate
;;;; blocks, which every PNG reader takes, and nothing in the tree has a deflate compressor
;;;; (chipz, which dexador loads, only inflates). A grey page is one byte a pixel, so an index
;;;; card at 200 DPI is about 600 KB; a colour page is three. RENDER-PAGE is grey by default,
;;;; which is what a page of text needs.

(in-package #:aion/pdfium)

;;; --- limits and refusals ----------------------------------------------------------------

(defvar *max-pdf-bytes* (* 64 1024 1024)
  "The largest PDF, in bytes, OPEN-PDF opens.")

(defvar *max-pdf-pages* 1000
  "The most pages a PDF OPEN-PDF opens may have.")

(defvar *max-render-pixels* 25000000
  "The most pixels RENDER-PAGE renders one page to: 25 million, an A4 page at about 500 DPI. A
colour page takes four bytes a pixel while pdfium draws it, so this bounds that buffer at 100 MB.")

(define-condition pdf-refused (error)
  ((reason :initarg :reason :reader pdf-refused-reason)
   (detail :initarg :detail :reader pdf-refused-detail))
  (:report (lambda (c s) (format s "aion/pdfium: ~A" (pdf-refused-detail c))))
  (:documentation "A PDF, page or render request refused. REASON is a keyword:
:TOO-LARGE, :TOO-MANY-PAGES, :TOO-MANY-PIXELS, :DPI, :PAGE, :EMPTY, :SOURCE, :CLOSED, or one of
pdfium's own, :FORMAT (not a PDF, or damaged), :PASSWORD, :SECURITY, :FILE or :UNKNOWN. DETAIL
says why, naming the limit, never the file's content."))

(defun %refuse (reason control &rest args)
  (error 'pdf-refused :reason reason :detail (apply #'format nil control args)))

;;; --- documents --------------------------------------------------------------------------

(defstruct (pdf-document (:constructor %make-document (handle buffer pages)) (:copier nil))
  "An open PDF. HANDLE is pdfium's document, BUFFER the foreign copy of the file it reads,
which must outlive the document. Both are NIL once CLOSE-PDF has run."
  handle buffer (pages 0 :type fixnum))

(defun %source-octets (source)
  "SOURCE, octets or a pathname or namestring, as an octet vector, refused before it is read
when it is over *MAX-PDF-BYTES*."
  (etypecase source
    ((vector (unsigned-byte 8))
     (when (> (length source) *max-pdf-bytes*)
       (%refuse :too-large "the PDF is ~D bytes, over *MAX-PDF-BYTES*, ~D" (length source) *max-pdf-bytes*))
     source)
    ((or pathname string)
     (with-open-file (in source :element-type '(unsigned-byte 8))
       (let ((n (file-length in)))
         (when (> n *max-pdf-bytes*)
           (%refuse :too-large "the PDF is ~D bytes, over *MAX-PDF-BYTES*, ~D" n *max-pdf-bytes*))
         (let* ((v (make-array n :element-type '(unsigned-byte 8)))
                (read (read-sequence v in)))
           (subseq v 0 read)))))))

(defun open-pdf (source &key password)
  "Open SOURCE, a PDF as octets or a pathname, with PASSWORD when it has one. Returns a
PDF-DOCUMENT; close it with CLOSE-PDF, or use WITH-PDF. Refuses, with PDF-REFUSED, a file over
*MAX-PDF-BYTES*, one with more than *MAX-PDF-PAGES* pages, and one pdfium cannot open, with its
reason (:FORMAT, :PASSWORD, :SECURITY, ...)."
  (unless (typep source '(or (vector (unsigned-byte 8)) pathname string))
    (%refuse :source "a PDF's source must be its octets or a pathname"))
  (let* ((octets (%source-octets source))
         (n (length octets)))
    (when (zerop n) (%refuse :empty "the PDF is empty"))
    (ensure-loaded)
    (with-pdfium
      (let ((buffer (cffi:foreign-alloc :uint8 :count n))
            (handle nil))
        (handler-bind ((error (lambda (e)
                                (declare (ignore e))
                                (when handle (%close-document handle))
                                (cffi:foreign-free buffer))))
          (loop for i below n do (setf (cffi:mem-aref buffer :uint8 i) (aref octets i)))
          (setf handle (%load-mem-document buffer n (or password (cffi:null-pointer))))
          (when (cffi:null-pointer-p handle)
            (setf handle nil)
            (let ((reason (or (cdr (assoc (%last-error) +errors+)) :unknown)))
              (%refuse reason "pdfium could not open the PDF (~(~A~))" reason)))
          (let ((pages (%page-count handle)))
            (when (> pages *max-pdf-pages*)
              (%refuse :too-many-pages "the PDF has ~D pages, over *MAX-PDF-PAGES*, ~D"
                       pages *max-pdf-pages*))
            (%make-document handle buffer pages)))))))

(defun close-pdf (document)
  "Close DOCUMENT and free what it holds. Closing one already closed does nothing."
  (with-pdfium
    (when (pdf-document-handle document)
      (%close-document (pdf-document-handle document))
      (cffi:foreign-free (pdf-document-buffer document))
      (setf (pdf-document-handle document) nil (pdf-document-buffer document) nil)))
  (values))

(defmacro with-pdf ((var source &rest options) &body body)
  "Run BODY with VAR bound to SOURCE opened with OPEN-PDF and OPTIONS, and close it after."
  `(let ((,var (open-pdf ,source ,@options)))
     (unwind-protect (progn ,@body) (close-pdf ,var))))

(defun page-count (document)
  "How many pages DOCUMENT has."
  (unless (pdf-document-handle document) (%refuse :closed "the document is closed"))
  (pdf-document-pages document))

;;; --- rendering ----------------------------------------------------------------------------

(defun render-page (document index &key (dpi 150) color)
  "Page INDEX, counted from 0, of DOCUMENT, rendered at DPI on white, with its annotations, as
PNG octets. Grey (one byte a pixel) unless COLOR is true. Returns (values PNG WIDTH HEIGHT).

DPI is a whole number from 1 to 1200. A page whose size at DPI is over *MAX-RENDER-PIXELS* is
refused before a bitmap is made.

The PNG is not compressed: its data is in stored deflate blocks, because the tree has no deflate
compressor. That is fine for what it is for, an image handed to OCR or to a model and not
stored; a grey index card at 200 DPI is about 600 KB. An app that stores the images should
compress them itself."
  (unless (pdf-document-handle document) (%refuse :closed "the document is closed"))
  (unless (and (integerp dpi) (<= 1 dpi 1200))
    (%refuse :dpi "DPI must be a whole number from 1 to 1200"))
  (unless (and (integerp index) (< -1 index (pdf-document-pages document)))
    (%refuse :page "the page number must be from 0 to ~D" (1- (pdf-document-pages document))))
  (with-pdfium
    (let ((page (%load-page (pdf-document-handle document) index)))
      (when (cffi:null-pointer-p page)
        (%refuse :page "pdfium could not load page ~D" index))
      (unwind-protect
           (let* ((width (max 1 (round (* (%page-width page) dpi) 72)))
                  (height (max 1 (round (* (%page-height page) dpi) 72))))
             (when (> (* width height) *max-render-pixels*)
               (%refuse :too-many-pixels "page ~D at ~D DPI is ~D by ~D pixels, over *MAX-RENDER-PIXELS*, ~D"
                        index dpi width height *max-render-pixels*))
             (let ((bitmap (%bitmap-create width height (if color +bitmap-bgra+ +bitmap-gray+)
                                           (cffi:null-pointer) 0)))
               (when (cffi:null-pointer-p bitmap)
                 (%refuse :too-many-pixels "pdfium could not make a ~D by ~D bitmap" width height))
               (unwind-protect
                    (progn
                      (%bitmap-fill-rect bitmap 0 0 width height #xFFFFFFFF)
                      (%render-page-bitmap bitmap page 0 0 width height 0 +render-annotations+)
                      (values (%png (%pixels bitmap width height color) width height color)
                              width height))
                 (%bitmap-destroy bitmap))))
        (%close-page page)))))

(defun %pixels (bitmap width height color)
  "BITMAP's pixels as rows of grey bytes, or of R G B bytes when COLOR, without the stride's
padding."
  (let* ((buffer (%bitmap-buffer bitmap))
         (stride (%bitmap-stride bitmap))
         (channels (if color 3 1))
         (out (make-array (* width height channels) :element-type '(unsigned-byte 8)))
         (k 0))
    (dotimes (y height out)
      (let ((row (* y stride)))
        (if color
            (dotimes (x width)
              (let ((at (+ row (* 4 x))))          ; B G R A
                (setf (aref out k) (cffi:mem-aref buffer :uint8 (+ at 2))
                      (aref out (+ k 1)) (cffi:mem-aref buffer :uint8 (+ at 1))
                      (aref out (+ k 2)) (cffi:mem-aref buffer :uint8 at))
                (incf k 3)))
            (dotimes (x width)
              (setf (aref out k) (cffi:mem-aref buffer :uint8 (+ row x)))
              (incf k)))))))

;;; --- the PNG ------------------------------------------------------------------------------

(defvar *crc-table*
  (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
    (dotimes (n 256 table)
      (let ((c n))
        (dotimes (k 8)
          (setf c (if (logbitp 0 c) (logxor #xEDB88320 (ash c -1)) (ash c -1))))
        (setf (aref table n) c))))
  "The CRC-32 table PNG's chunks use.")

(defun %crc32 (octets &optional (start 0) (end (length octets)))
  (let ((c #xFFFFFFFF))
    (loop for i from start below end
          do (setf c (logxor (aref *crc-table* (logand (logxor c (aref octets i)) #xFF)) (ash c -8))))
    (logxor c #xFFFFFFFF)))

(defun %png (pixels width height color)
  "PIXELS, rows of grey or R G B bytes, as a PNG: 8 bits a channel, filter None on every row,
and the zlib stream in stored deflate blocks."
  (let* ((row-bytes (* width (if color 3 1)))
         (raw-length (* height (1+ row-bytes)))
         (blocks (max 1 (ceiling raw-length 65535)))
         (zlib-length (+ 2 (* 5 blocks) raw-length 4))
         (out (make-array (+ 8 25 (+ 12 zlib-length) 12) :element-type '(unsigned-byte 8)))
         (at 0) (adler-a 1) (adler-b 0))
    (labels ((put (b) (setf (aref out at) b) (incf at))
             (put32 (n) (put (ldb (byte 8 24) n)) (put (ldb (byte 8 16) n))
                        (put (ldb (byte 8 8) n)) (put (ldb (byte 8 0) n)))
             (chunk-start (length type) (put32 length) (loop for ch across type do (put (char-code ch))))
             (chunk-end (data-start) (put32 (%crc32 out (- data-start 4) at)))
             (raw (b) (put b)
                      (setf adler-a (mod (+ adler-a b) 65521)
                            adler-b (mod (+ adler-b adler-a) 65521))))
      (loop for b across #(137 80 78 71 13 10 26 10) do (put b))
      ;; IHDR
      (chunk-start 13 "IHDR")
      (let ((data at))
        (put32 width) (put32 height) (put 8) (put (if color 2 0)) (put 0) (put 0) (put 0)
        (chunk-end data))
      ;; IDAT: zlib header (deflate, 32 KB window, no preset dictionary, fastest), stored blocks
      (chunk-start zlib-length "IDAT")
      (let ((data at) (left raw-length) (row 0) (col -1))
        (put #x78) (put #x01)
        (loop while (plusp left)
              do (let ((n (min left 65535)))
                   (put (if (= n left) 1 0))
                   (put (ldb (byte 8 0) n)) (put (ldb (byte 8 8) n))
                   (put (ldb (byte 8 0) (logxor n #xFFFF))) (put (ldb (byte 8 8) (logxor n #xFFFF)))
                   (dotimes (i n)
                     ;; col -1 is a row's filter byte, 0 (None)
                     (raw (if (= col -1) 0 (aref pixels (+ (* row row-bytes) col))))
                     (incf col)
                     (when (= col row-bytes) (setf col -1) (incf row)))
                   (decf left n)))
        (put32 (logior (ash adler-b 16) adler-a))
        (chunk-end data))
      ;; IEND
      (chunk-start 0 "IEND")
      (chunk-end at)
      out)))
