;;;; tests/public-image.lisp --- a public copy of an image for a link-preview card (#830).
;;;;
;;;; The fixtures are built here, byte by byte, in the shape a phone writes: an EXIF block with
;;;; an Orientation field and a GPS block, XMP, IPTC, a comment, a colour profile, the pixel
;;;; data, and bytes after the end of the image. Every piece of metadata carries a word ending
;;;; in SECRET, so a test can show that none of it reached the copy, and the pixel data is
;;;; compared byte for byte, which is what shows that removing the metadata did not touch the
;;;; image. No test decodes pixels: the format work is all at the level of segments and chunks.

(in-package #:hermes/blob/tests)

(def-suite hermes-blob-public-image :description "Public copies of images (#830)." :in hermes-blob)
(in-suite hermes-blob-public-image)

;;; --- building fixtures ---------------------------------------------------------

(defun bytes (&rest parts)
  "One octet vector of PARTS: strings (as ASCII), integers (one byte each), and sequences of
bytes."
  (let ((out '()))
    (dolist (p parts)
      (etypecase p
        (string (loop for c across p do (push (char-code c) out)))
        (integer (push p out))
        (sequence (map nil (lambda (b) (push b out)) p))))
    (coerce (nreverse out) '(simple-array (unsigned-byte 8) (*)))))

(defun be (value width) (loop for shift from (* 8 (1- width)) downto 0 by 8 collect (ldb (byte 8 shift) value)))
(defun le (value width) (reverse (be value width)))

(defun tiff-with-gps (orientation &key (little-endian t))
  "A TIFF structure as a phone's EXIF block holds it: IFD0 with ORIENTATION and a pointer to a
GPS block, then the GPS block's text."
  (flet ((u16 (v) (if little-endian (le v 2) (be v 2)))
         (u32 (v) (if little-endian (le v 4) (be v 4))))
    (bytes (if little-endian "II" "MM") (u16 42) (u32 8)
           (u16 2)
           (u16 #x0112) (u16 3) (u32 1) (u16 orientation) 0 0
           (u16 #x8825) (u16 4) (u32 1) (u32 38)
           (u32 0)
           "GPSSECRET-51.5074N-0.1278W")))

(defun jpeg-segment (marker &rest payload)
  (let ((body (apply #'bytes payload)))
    (bytes #xFF marker (be (+ 2 (length body)) 2) body)))

(defparameter +jpeg-image-part+
  (bytes (jpeg-segment #xDB 0 (make-list 64 :initial-element 1))           ; DQT
         (jpeg-segment #xC0 8 (be 20 2) (be 30 2) 3 1 #x22 0 2 #x11 1 3 #x11 1) ; SOF0, 30x20
         (jpeg-segment #xC4 0 (make-list 16 :initial-element 0))           ; DHT
         (jpeg-segment #xDA 3 1 0 2 #x11 3 #x11 0 #x3F 0)                  ; SOS
         #x12 #x34 #xFF #x00 #x56 #xFF #xD0 #x78 #x9A                      ; entropy data, a stuffed FF, RST0
         #xFF #xD9)                                                        ; EOI
  "A JPEG's frame, tables, scan and end, which the copy must carry byte for byte.")

(defun jpeg-fixture (&key (orientation 6) (little-endian t) (image +jpeg-image-part+))
  (bytes #xFF #xD8
         (jpeg-segment #xE0 "JFIF" 0 1 1 1 (be 72 2) (be 72 2) 1 1 #xAA #xBB #xCC) ; with a 1x1 thumbnail
         (jpeg-segment #xE1 "Exif" 0 0 (tiff-with-gps orientation :little-endian little-endian))
         (jpeg-segment #xE1 "http://ns.adobe.com/xap/1.0/" 0 "<x:xmpmeta>XMPSECRET</x:xmpmeta>")
         (jpeg-segment #xED "Photoshop 3.0" 0 "IPTCSECRET")
         (jpeg-segment #xE2 "ICC_PROFILE" 0 1 1 "ICCDATA")
         (jpeg-segment #xFE "COMMENTSECRET")
         image
         "TRAILERSECRET"))

(defun png-chunk (type &rest data)
  (let ((body (apply #'bytes type data)))
    (bytes (be (- (length body) 4) 4) body (ironclad:digest-sequence :crc32 body))))

(defparameter +png-idat+ (png-chunk "IDAT" "IDATBYTES" #x00 #xFF #x10))

(defun png-fixture (&key (orientation 8) (idat t))
  (bytes #x89 "PNG" #x0D #x0A #x1A #x0A
         (png-chunk "IHDR" (be 30 4) (be 20 4) 8 2 0 0 0)
         (png-chunk "eXIf" (tiff-with-gps orientation :little-endian nil))
         (png-chunk "tEXt" "Comment" 0 "TEXTSECRET")
         (png-chunk "iCCP" "icc" 0 0 "ICCDATA")
         (if idat +png-idat+ #())
         (png-chunk "tIME" 7 234 1 2 3 4 5)
         (png-chunk "caBX" "C2PASECRET")
         (png-chunk "IEND")
         "TRAILERSECRET"))

(defun riff-chunk (fourcc &rest data)
  (let ((body (apply #'bytes data)))
    (bytes fourcc (le (length body) 4) body (if (oddp (length body)) '(0) '()))))

(defparameter +webp-vp8+ (riff-chunk "VP8 " 0 0 0 #x9D #x01 #x2A (le 30 2) (le 20 2) "VP8DATA"))

(defun webp-fixture (&key (orientation 3))
  (let ((body (bytes "WEBP"
                     (riff-chunk "VP8X" #x2C 0 0 0 (le 29 3) (le 19 3))   ; ICC, EXIF, XMP
                     (riff-chunk "ICCP" "ICCDATA")
                     +webp-vp8+
                     (riff-chunk "EXIF" (tiff-with-gps orientation))
                     (riff-chunk "XMP " "XMPSECRET"))))
    (bytes "RIFF" (le (length body) 4) body "TRAILERSECRET")))

;;; --- reading results -----------------------------------------------------------

(defun contains-p (octets string)
  (search (bytes string) octets))

(defun no-secret-p (octets)
  "True when OCTETS carry none of the fixtures' metadata."
  (notany (lambda (s) (contains-p octets s))
          '("SECRET" "GPS" "Photoshop" "xap/1.0")))

(defun ends-with-p (octets tail)
  (let ((start (- (length octets) (length tail))))
    (and (>= start 0) (equalp (subseq octets start) tail))))

(defun jpeg-markers (v)
  "The markers of V's segments before its first scan, in order."
  (loop with pos = 2
        for m = (aref v (1+ pos))
        collect m
        until (= m #xDA)
        do (incf pos (+ 2 (logior (ash (aref v (+ pos 2)) 8) (aref v (+ pos 3)))))))

(defun png-chunk-types (v)
  (loop with pos = 8
        while (< pos (length v))
        for len = (logior (ash (aref v pos) 24) (ash (aref v (+ pos 1)) 16)
                          (ash (aref v (+ pos 2)) 8) (aref v (+ pos 3)))
        collect (map 'string #'code-char (subseq v (+ pos 4) (+ pos 8)))
        do (incf pos (+ 12 len))))

(defun riff-chunk-ids (v)
  (loop with pos = 12
        while (< pos (length v))
        for len = (logior (aref v (+ pos 4)) (ash (aref v (+ pos 5)) 8)
                          (ash (aref v (+ pos 6)) 16) (ash (aref v (+ pos 7)) 24))
        collect (map 'string #'code-char (subseq v pos (+ pos 4)))
        do (incf pos (+ 8 len (if (oddp len) 1 0)))))

(defun refusal (octets)
  (handler-case (progn (b:strip-image-metadata octets) nil)
    (b:blob-image-refused (c) (b:blob-image-refused-reason c))))

;;; --- removing metadata: JPEG ---------------------------------------------------

(test a-jpeg-loses-its-metadata-and-keeps-its-pixels-and-colour-profile
  (multiple-value-bind (out width height type extension) (b:strip-image-metadata (jpeg-fixture))
    (is-true (no-secret-p out))
    (is-true (ends-with-p out +jpeg-image-part+) "The frame, tables, scan and EOI, byte for byte.")
    (is-true (contains-p out "ICCDATA"))
    (is (equal '(#xE0 #xE1 #xE2 #xDB #xC0 #xC4 #xDA) (jpeg-markers out))
        "JFIF, the new EXIF block, the colour profile, then the image.")
    (is (= 16 (logior (ash (aref out 4) 8) (aref out 5))) "The JFIF thumbnail is gone.")
    (is (equal '(20 30) (list width height)) "Orientation 6 turns the 30x20 image upright.")
    (is (equal '("image/jpeg" "jpg") (list type extension)))))

(test the-new-exif-block-holds-only-the-orientation
  (dolist (little-endian '(t nil))
    (let* ((out (b:strip-image-metadata (jpeg-fixture :orientation 6 :little-endian little-endian)))
           (exif (search (bytes "Exif" 0 0) out)))
      (is-true exif)
      (is (= 6 (b::%exif-orientation out (+ exif 6) (length out))))
      (is (= (+ 2 6 26) (logior (ash (aref out (- exif 2)) 8) (aref out (- exif 1))))
          "Its length: the identifier and a 26-byte TIFF structure with one field."))))

(test a-jpeg-shown-as-stored-gets-no-exif-block
  (multiple-value-bind (out width height) (b:strip-image-metadata (jpeg-fixture :orientation 1))
    (is-false (contains-p out "Exif"))
    (is (equal '(#xE0 #xE2 #xDB #xC0 #xC4 #xDA) (jpeg-markers out)))
    (is (equal '(30 20) (list width height)))))

;;; --- removing metadata: PNG and WebP -------------------------------------------

(test a-png-loses-its-metadata-and-keeps-its-pixels
  (multiple-value-bind (out width height type) (b:strip-image-metadata (png-fixture))
    (is-true (no-secret-p out))
    (is-true (search +png-idat+ out) "The IDAT chunk, byte for byte.")
    (is (equal '("IHDR" "eXIf" "iCCP" "IDAT" "IEND") (png-chunk-types out)))
    (is (equal '(20 30) (list width height)) "Orientation 8 turns it upright.")
    (is (string= "image/png" type))
    (let* ((at (search (bytes "eXIf") out))
           (len (logior (ash (aref out (- at 2)) 8) (aref out (- at 1))))
           (body (subseq out at (+ at 4 len))))
      (is (equalp (ironclad:digest-sequence :crc32 body) (subseq out (+ at 4 len) (+ at 8 len)))
          "The new chunk's CRC is right.")
      (is (= 8 (b::%exif-orientation out (+ at 4) (+ at 4 len)))))))

(test a-webp-loses-its-metadata-and-keeps-its-pixels
  (multiple-value-bind (out width height type) (b:strip-image-metadata (webp-fixture))
    (is-true (no-secret-p out))
    (is-true (search +webp-vp8+ out) "The VP8 chunk, byte for byte.")
    (is (equal '("VP8X" "ICCP" "VP8 " "EXIF") (riff-chunk-ids out)))
    (is (= #x28 (aref out 20)) "VP8X says ICC and EXIF, no longer XMP.")
    (is (= (- (length out) 8) (logior (aref out 4) (ash (aref out 5) 8))) "The RIFF size is right.")
    (is (equal '(30 20) (list width height)) "Orientation 3 is upside down, not turned.")
    (is (string= "image/webp" type))))

(test a-webp-with-no-orientation-to-keep-says-it-has-no-exif
  (let ((out (b:strip-image-metadata (webp-fixture :orientation 1))))
    (is (equal '("VP8X" "ICCP" "VP8 ") (riff-chunk-ids out)))
    (is (= #x20 (aref out 20)))))

;;; --- refusals ------------------------------------------------------------------

(test only-jpeg-png-and-webp-are-accepted
  (is (eq :unsupported-format (refusal (bytes "<svg xmlns=\"http://www.w3.org/2000/svg\"><script/></svg>"))))
  (is (eq :unsupported-format (refusal (bytes "GIF89a" 1 0 1 0 0 0 0 #x3B))))
  (is (eq :unsupported-format (refusal (bytes 0 0 0 #x18 "ftypheic" 0 0 0 0 "mif1heic"))) "HEIC")
  (is (eq :unsupported-format (refusal (bytes)))))

(test a-file-whose-structure-does-not-parse-is-refused
  (let ((jpeg (jpeg-fixture)))
    (is (eq :malformed (refusal (subseq jpeg 0 (- (length jpeg) 20)))) "cut before EOI")
    (is (eq :malformed (refusal (subseq jpeg 0 30))) "cut inside a segment"))
  (is (eq :malformed (refusal (png-fixture :idat nil))) "a PNG with no pixel data")
  (let ((webp (webp-fixture)))
    (is (eq :malformed (refusal (subseq webp 0 40))) "a RIFF size longer than the file")))

;;; --- the public copy -----------------------------------------------------------

(defun put-octets (store bucket key octets)
  (b:put-blob store bucket key (make-instance 'b::%octet-source :octets octets)
              :content-type "image/jpeg"))

(defun get-octets (store bucket key)
  (b:with-blob-stream (in store bucket key)
    (let ((v (make-array 100000 :element-type '(unsigned-byte 8))))
      (subseq v 0 (read-sequence v in)))))

(defmacro with-two-stores ((private public) &body body)
  "PRIVATE, a filesystem store with no URL, and PUBLIC, one served from img.example.com."
  `(with-temp-store (,private)
     (with-temp-store (,public :base-url "https://img.example.com/")
       ,@body)))

(defun counting (name fn)
  "Call FN while counting calls of the function NAME. Returns the count."
  (let ((count 0))
    (sb-int:encapsulate name 'count (lambda (f &rest args) (incf count) (apply f args)))
    (unwind-protect (funcall fn)
      (sb-int:unencapsulate name 'count))
    count))

(test a-private-image-gets-a-permanent-public-url-without-its-metadata
  (with-two-stores (private public)
    (put-octets private "media" "members/7/photo.jpg" (jpeg-fixture))
    (multiple-value-bind (url width height type)
        (b:public-image-url private "media" "members/7/photo.jpg" public "cards")
      (is-true (and (stringp url) (eql 0 (search "https://img.example.com/cards/og/" url))) "~A" url)
      (is (null (position #\? url)) "No query string, so nothing that expires.")
      (is (null (search "members" url)) "The private key is not in the public one.")
      (is (equal '(20 30 "image/jpeg") (list width height type)))
      (let ((copy (first (b:list-blobs public "cards" :prefix "og/"))))
        (is-true (search "-20x30.jpg" copy))
        (is (equalp (b:strip-image-metadata (jpeg-fixture)) (get-octets public "cards" copy))
            "The copy holds the stripped bytes.")))))

(test a-second-call-reads-and-writes-nothing
  (with-two-stores (private public)
    (put-octets private "media" "a.jpg" (jpeg-fixture))
    (let ((first-url (b:public-image-url private "media" "a.jpg" public "cards"))
          (second-url nil))
      (is (= 0 (counting 'b::%read-image
                         (lambda ()
                           (is (= 0 (counting 'b:put-blob
                                              (lambda ()
                                                (setf second-url
                                                      (b:public-image-url private "media" "a.jpg" public "cards"))))))))))
      (is (equal first-url second-url)))))

(test a-changed-original-gets-a-new-copy-and-the-old-one-is-deleted
  (with-two-stores (private public)
    (put-octets private "media" "a.jpg" (jpeg-fixture :orientation 6))
    (let ((old (b:public-image-url private "media" "a.jpg" public "cards")))
      (put-octets private "media" "a.jpg" (jpeg-fixture :orientation 1))
      (multiple-value-bind (new width height) (b:public-image-url private "media" "a.jpg" public "cards")
        (is (string/= old new))
        (is (equal '(30 20) (list width height)))
        (is (= 1 (length (b:list-blobs public "cards" :prefix "og/"))) "Only the new copy is left.")))))

(test two-images-keep-separate-copies-and-delete-removes-only-its-own
  (with-two-stores (private public)
    (put-octets private "media" "a.jpg" (jpeg-fixture))
    (put-octets private "media" "b.png" (png-fixture))
    (b:public-image-url private "media" "a.jpg" public "cards")
    (b:public-image-url private "media" "b.png" public "cards")
    (is (= 2 (length (b:list-blobs public "cards" :prefix "og/"))))
    (is (= 1 (b:delete-public-images "media" "a.jpg" public "cards")))
    (is (= 1 (length (b:list-blobs public "cards" :prefix "og/"))))
    (is (= 0 (b:delete-public-images "media" "a.jpg" public "cards")) "Deleting again finds none.")))

(test a-refused-image-writes-nothing-and-names-the-blob
  (with-two-stores (private public)
    (put-octets private "media" "a.svg" (bytes "<svg/>"))
    (put-octets private "media" "big.jpg" (jpeg-fixture))
    (let ((c (handler-case (b:public-image-url private "media" "a.svg" public "cards")
               (b:blob-unsupported (c) c))))
      (is (typep c 'b:blob-image-refused) "A BLOB-UNSUPPORTED, so an app's fallback catches it.")
      (is (eq :unsupported-format (b:blob-image-refused-reason c)))
      (is (equal "a.svg" (b:blob-error-key c))))
    (let ((c (handler-case (b:public-image-url private "media" "big.jpg" public "cards" :max-bytes 100)
               (b:blob-image-refused (c) c))))
      (is (eq :too-large (b:blob-image-refused-reason c)))
      (is (= 100 (b:blob-image-refused-limit c))))
    (is (null (b:list-blobs public "cards" :prefix "og/")))))

;;; --- Cache-Control on put-blob -------------------------------------------------

(test the-s3-store-sends-cache-control-when-given-one
  (flet ((headers (&rest keys)
           (multiple-value-bind (result calls)
               (call-with-recorded-s3 ""
                 (lambda () (apply #'b:put-blob (test-s3-store) "media" "a.jpg"
                                   (make-instance 'b::%octet-source :octets (bytes "x")) keys)))
             (declare (ignore result))
             (getf (first calls) :extra-headers))))
    (is (equal "public, max-age=60" (cdr (assoc "cache-control" (headers :cache-control "public, max-age=60")
                                                :test #'string=))))
    (is (null (assoc "cache-control" (headers) :test #'string=)))))

(test a-cache-control-with-a-control-character-is-refused
  (with-temp-store (store)
    (signals b:blob-invalid-metadata
      (b:put-blob store "media" "a.jpg" (make-instance 'b::%octet-source :octets (bytes "x"))
                  :cache-control (format nil "public~C~CX-Evil: 1" #\Return #\Linefeed)))
    (signals b:blob-invalid-metadata
      (b:put-blob store "media" "a.jpg" (make-instance 'b::%octet-source :octets (bytes "x"))
                  :cache-control ""))
    (is-false (b:blob-exists-p store "media" "a.jpg"))))
