;;;; public-image.lisp --- a public copy of an image for a link-preview card (#830).
;;;;
;;;; A page's og:image must be a URL a crawler can fetch without cookies and that does not
;;;; expire, and an app keeps its members' images in a private bucket. PUBLIC-IMAGE-URL copies
;;;; one image into a store the app configured as public, and returns the copy's permanent URL
;;;; with the image's width and height.
;;;;
;;;; The copy has its metadata removed first. A phone photo's EXIF block carries the GPS
;;;; position it was taken at, the camera's serial number and a thumbnail that can show the
;;;; uncropped original, and none of that may become public. The metadata sits in segments
;;;; (JPEG) or chunks (PNG, WebP) apart from the pixel data, so it is removed by copying only the
;;;; segments and chunks an image needs, without decoding the pixels and without an image
;;;; library. What is kept is listed per format below; everything else is dropped, including
;;;; segments and chunks this file does not know. The one EXIF field kept is Orientation, in a
;;;; new EXIF block holding nothing else, because a phone photo is often stored sideways and
;;;; turned upright for display by that field.
;;;;
;;;; The copy is not resized (#846 asks the maintainer about an image library for that).

(cl:in-package #:hermes/blob)

(define-condition blob-image-refused (blob-unsupported)
  ((reason :initarg :reason :reader blob-image-refused-reason)
   (size :initarg :size :initform nil :reader blob-image-refused-size)
   (limit :initarg :limit :initform nil :reader blob-image-refused-limit))
  (:report (lambda (c s)
             (format s "no public copy of the image in bucket ~A: ~A"
                     (or (blob-error-bucket c) "?")
                     (ecase (blob-image-refused-reason c)
                       (:unsupported-format "it is not a JPEG, PNG or WebP image")
                       (:too-large (format nil "it is over the limit of ~:D bytes" (blob-image-refused-limit c)))
                       (:malformed "its structure could not be read, so its metadata could not be removed")))))
  (:documentation
   "PUBLIC-IMAGE-URL or STRIP-IMAGE-METADATA made no copy (#830). REASON is
:UNSUPPORTED-FORMAT (anything but JPEG, PNG and WebP, judged from the bytes: SVG, GIF and HEIC
among them), :TOO-LARGE (over MAX-BYTES; SIZE and LIMIT say by how much) or :MALFORMED (a file
whose segments or chunks do not parse, which is never published unchanged). A subclass of
BLOB-UNSUPPORTED, so an app that falls back to the site's image on that falls back here too."))

(defparameter *public-image-cache-control* "public, max-age=86400"
  "The Cache-Control a public copy is written with, unless PUBLIC-IMAGE-URL is given another.
A copy's key never changes content, so it could be cached for a year, but a copy deleted by
DELETE-PUBLIC-IMAGES stays in a CDN's cache for up to max-age, and one day keeps that short.")

(defconstant +default-max-image-bytes+ 5242880
  "5 MiB, the largest image PUBLIC-IMAGE-URL copies unless told otherwise. Third-party guides
give it as X's limit for a card image.")

;;; --- reading and writing octets ---------------------------------------------

(deftype %image-octets () '(simple-array (unsigned-byte 8) (*)))

(defun %img-u16be (v i) (logior (ash (aref v i) 8) (aref v (1+ i))))
(defun %img-u32be (v i) (logior (ash (%img-u16be v i) 16) (%img-u16be v (+ i 2))))
(defun %img-u16le (v i) (logior (aref v i) (ash (aref v (1+ i)) 8)))
(defun %img-u24le (v i) (logior (%img-u16le v i) (ash (aref v (+ i 2)) 16)))
(defun %img-u32le (v i) (logior (%img-u16le v i) (ash (%img-u16le v (+ i 2)) 16)))

(defun %img-be (value width)
  "VALUE as WIDTH bytes, most significant first, as a list."
  (loop for shift from (* 8 (1- width)) downto 0 by 8 collect (ldb (byte 8 shift) value)))

(defun %img-le (value width)
  "VALUE as WIDTH bytes, least significant first, as a list."
  (reverse (%img-be value width)))

(defun %img-ascii-at-p (v i string)
  "True when the bytes of V from I spell STRING, whose characters are all ASCII."
  (and (<= (+ i (length string)) (length v))
       (loop for c across string for j from i always (= (aref v j) (char-code c)))))

(defun %img-ascii (string)
  (map 'list #'char-code string))

(defun %img-concat (parts)
  "One octet vector of PARTS, each an octet vector or a list of bytes."
  (let ((out (make-array (reduce #'+ parts :key #'length) :element-type '(unsigned-byte 8)))
        (i 0))
    (dolist (p parts out)
      (replace out p :start1 i)
      (incf i (length p)))))

(defun %img-malformed ()
  (error 'blob-image-refused :reason :malformed))

(defclass %octet-source (sb-gray:fundamental-binary-input-stream)
  ((octets :initarg :octets :reader %octet-source-octets)
   (index :initform 0 :accessor %octet-source-index))
  (:documentation "A binary input stream over an octet vector, so PUT-BLOB can take one."))

(defmethod cl:stream-element-type ((s %octet-source)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s %octet-source))
  (let ((v (%octet-source-octets s)) (i (%octet-source-index s)))
    (if (>= i (length v))
        :eof
        (progn (setf (%octet-source-index s) (1+ i)) (aref v i)))))

(defmethod sb-gray:stream-read-sequence ((s %octet-source) seq &optional (start 0) end)
  (let* ((v (%octet-source-octets s))
         (i (%octet-source-index s))
         (n (min (- (or end (length seq)) start) (- (length v) i))))
    (replace seq v :start1 start :end1 (+ start n) :start2 i)
    (setf (%octet-source-index s) (+ i n))
    (+ start n)))

;;; --- the EXIF Orientation field ---------------------------------------------

(defun %exif-orientation (v start end)
  "The Orientation value, 1 to 8, in the TIFF structure (an EXIF block's body) in V from
START to END, or NIL when there is none or the structure does not parse."
  (block nil
    (unless (<= (+ start 8) end) (return nil))
    (let ((le (cond ((%img-ascii-at-p v start "II") t)
                    ((%img-ascii-at-p v start "MM") nil)
                    (t (return nil)))))
      (flet ((u16 (i) (if le (%img-u16le v i) (%img-u16be v i)))
             (u32 (i) (if le (%img-u32le v i) (%img-u32be v i))))
        (let ((ifd (+ start (u32 (+ start 4)))))
          (unless (<= (+ ifd 2) end) (return nil))
          (loop for e from (+ ifd 2) by 12
                repeat (u16 ifd)
                while (<= (+ e 12) end)
                when (and (= (u16 e) #x0112) (= (u16 (+ e 2)) 3) (= (u32 (+ e 4)) 1))
                  do (let ((value (u16 (+ e 8))))
                       (return (and (<= 1 value 8) value)))))))))

(defun %orientation-tiff (orientation)
  "A TIFF structure, big-endian, whose only field is ORIENTATION: 26 bytes."
  (append (%img-ascii "MM") '(0 42) '(0 0 0 8)    ; header, IFD0 at offset 8
          '(0 1)                                  ; one entry
          '(#x01 #x12) '(0 3) '(0 0 0 1)          ; Orientation, SHORT, count 1
          (%img-be orientation 2) '(0 0)          ; the value, left-justified
          '(0 0 0 0)))                            ; no next IFD

(defun %turned-p (orientation)
  "True when ORIENTATION shows the image turned a quarter, so its width and height swap."
  (and orientation (<= 5 orientation 8)))

;;; --- JPEG ----------------------------------------------------------------------
;;;
;;; Kept: the frame and scan segments (SOFn, DHT, DAC, DQT, DRI, DNL, DHP, EXP, SOS and the
;;; entropy-coded data after each SOS, restart markers included), APP0 JFIF with its
;;; thumbnail removed, APP2 ICC_PROFILE and APP14 Adobe (which says how CMYK is stored).
;;; Dropped: every other APPn (EXIF, XMP, IPTC, MPF's extra images), COM, and anything after
;;; EOI, where some phones append a second image or a video.

(defun %jpeg-sof-p (m)
  (and (<= #xC0 m #xCF) (not (member m '(#xC4 #xC8 #xCC)))))

(defun %jpeg-kept-marker-p (m)
  (or (%jpeg-sof-p m) (member m '(#xC4 #xCC #xDA #xDB #xDC #xDD #xDE #xDF))))

(defun %jpeg-entropy-end (v pos)
  "Where the entropy-coded data that starts at POS ends: the FF of the next marker that is not
a stuffed zero or a restart marker."
  (loop for i from pos below (1- (length v))
        when (and (= (aref v i) #xFF)
                  (let ((next (aref v (1+ i))))
                    (not (or (= next 0) (= next #xFF) (<= #xD0 next #xD7)))))
          do (return i)
        finally (%img-malformed)))

(defun %strip-jpeg (v)
  (let ((n (length v)) (pos 2) (jfif nil) (pieces '()) (orientation nil)
        (width nil) (height nil) (scan nil))
    (loop
      (unless (and (< (1+ pos) n) (= (aref v pos) #xFF)) (%img-malformed))
      (loop while (and (< (+ pos 2) n) (= (aref v (1+ pos)) #xFF)) do (incf pos))
      (let ((m (aref v (1+ pos))))
        (cond ((= m #xD9) (push #(#xFF #xD9) pieces) (return))
              ((or (<= #xD0 m #xD7) (= m #x01))
               (push (subseq v pos (+ pos 2)) pieces)
               (incf pos 2))
              ((or (= m #xD8) (= m 0)) (%img-malformed))
              (t
               (unless (<= (+ pos 4) n) (%img-malformed))
               (let* ((len (%img-u16be v (+ pos 2)))
                      (end (+ pos 2 len))
                      (p (+ pos 4)))
                 (unless (and (>= len 2) (<= end n)) (%img-malformed))
                 (cond ((= m #xE0)
                        (when (and (null jfif) (>= len 16) (%img-ascii-at-p v p (format nil "JFIF~C" (code-char 0))))
                          ;; Version, units and density kept; thumbnail width and height 0.
                          (setf jfif (%img-concat (list '(#xFF #xE0 0 16) (subseq v p (+ p 12)) '(0 0))))))
                       ((= m #xE1)
                        (when (%img-ascii-at-p v p (format nil "Exif~C~C" (code-char 0) (code-char 0)))
                          (setf orientation (or orientation (%exif-orientation v (+ p 6) end)))))
                       ((= m #xE2)
                        (when (%img-ascii-at-p v p (format nil "ICC_PROFILE~C" (code-char 0)))
                          (push (subseq v pos end) pieces)))
                       ((= m #xEE)
                        ;; Kept as its 12 standard bytes ("Adobe", version, two flag words and
                        ;; the colour transform), which a decoder needs for CMYK and YCCK; a
                        ;; writer can append anything after them.
                        (when (and (>= len 14) (%img-ascii-at-p v p "Adobe"))
                          (push (%img-concat (list '(#xFF #xEE 0 14) (subseq v p (+ p 12))))
                                pieces)))
                       ((%jpeg-kept-marker-p m)
                        (when (and (%jpeg-sof-p m) (null width))
                          (unless (>= len 8) (%img-malformed))
                          (setf height (%img-u16be v (+ p 1))
                                width (%img-u16be v (+ p 3))))
                        (push (subseq v pos end) pieces)))
                 (setf pos end)
                 (when (= m #xDA)
                   (setf scan t)
                   (let ((e (%jpeg-entropy-end v pos)))
                     (push (subseq v pos e) pieces)
                     (setf pos e))))))))
    (unless (and scan width height (plusp width) (plusp height)) (%img-malformed))
    (let ((exif (when (and orientation (/= orientation 1))
                  (let ((body (append (%img-ascii "Exif") '(0 0) (%orientation-tiff orientation))))
                    (append '(#xFF #xE1) (%img-be (+ 2 (length body)) 2) body)))))
      (values (%img-concat (list* '(#xFF #xD8) (or jfif #()) (or exif '()) (reverse pieces)))
              width height orientation))))

;;; --- PNG -----------------------------------------------------------------------
;;;
;;; Kept: the chunks that draw the image or say how its colours and size are meant (IHDR, PLTE,
;;; IDAT, IEND, tRNS, cHRM, gAMA, iCCP, sBIT, sRGB, cICP, mDCV, cLLI, bKGD, pHYs) and an
;;; animated PNG's (acTL, fcTL, fdAT). Dropped: eXIf, the text chunks, tIME, every private or
;;; unknown chunk (C2PA provenance among them), and anything after IEND.

(defparameter +png-signature+ '(#x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A))

(defparameter +png-kept-chunks+
  '("IHDR" "PLTE" "IDAT" "IEND" "tRNS" "cHRM" "gAMA" "iCCP" "sBIT" "sRGB" "cICP" "mDCV"
    "cLLI" "bKGD" "pHYs" "acTL" "fcTL" "fdAT"))

(defun %png-chunk (type data)
  "A PNG chunk of TYPE (a string) holding DATA (a list of bytes), with its CRC."
  (let ((body (append (%img-ascii type) data)))
    (append (%img-be (length data) 4) body
            (coerce (ironclad:digest-sequence :crc32 (coerce body '%image-octets)) 'list))))

(defun %strip-png (v)
  (let ((n (length v)) (pos 8) (pieces '()) (orientation nil) (width nil) (height nil)
        (idat nil))
    (loop
      (unless (<= (+ pos 12) n) (%img-malformed))
      (let* ((len (%img-u32be v pos))
             (type (map 'string #'code-char (subseq v (+ pos 4) (+ pos 8))))
             (end (+ pos 12 len)))
        (unless (<= end n) (%img-malformed))
        (cond ((null width)
               (unless (and (string= type "IHDR") (= len 13)) (%img-malformed))
               (setf width (%img-u32be v (+ pos 8)) height (%img-u32be v (+ pos 12))))
              ((string= type "eXIf")
               (setf orientation (or orientation (%exif-orientation v (+ pos 8) (+ pos 8 len))))))
        (when (string= type "IDAT") (setf idat t))
        (when (member type +png-kept-chunks+ :test #'string=)
          (push (subseq v pos end) pieces))
        (setf pos end)
        (when (string= type "IEND") (return))))
    (unless (and idat (plusp width) (plusp height)) (%img-malformed))
    (let* ((pieces (reverse pieces))
           (exif (when (and orientation (/= orientation 1))
                   (%png-chunk "eXIf" (%orientation-tiff orientation)))))
      ;; IHDR first, then the new eXIf, which the PNG specification wants before IDAT.
      (values (%img-concat (list* +png-signature+ (first pieces) (or exif '()) (rest pieces)))
              width height orientation))))

;;; --- WebP ----------------------------------------------------------------------
;;;
;;; Kept: VP8X, ICCP, ANIM, ANMF, ALPH, VP8 and VP8L. Dropped: EXIF, XMP and every unknown
;;; chunk, and anything past the RIFF size. A simple WebP (one VP8 or VP8L chunk, no VP8X) has
;;; nowhere to keep metadata, and comes out as it went in.

(defparameter +webp-kept-chunks+ '("VP8X" "ICCP" "ANIM" "ANMF" "ALPH" "VP8 " "VP8L"))

(defun %webp-chunk (fourcc data)
  "A RIFF chunk of FOURCC holding DATA (an octet vector or list), padded to an even length, as a
list of parts for %IMG-CONCAT. DATA is not copied, so a large chunk costs no conses."
  (list* (append (%img-ascii fourcc) (%img-le (length data) 4))
         data
         (when (oddp (length data)) (list '(0)))))

(defun %webp-size (fourcc v p len)
  "The width and height a VP8, VP8L or VP8X chunk's data at P (LEN bytes) declares."
  (cond ((string= fourcc "VP8X")
         (unless (>= len 10) (%img-malformed))
         (values (1+ (%img-u24le v (+ p 4))) (1+ (%img-u24le v (+ p 7)))))
        ((string= fourcc "VP8 ")
         (unless (and (>= len 10) (= (aref v (+ p 3)) #x9D) (= (aref v (+ p 4)) #x01)
                      (= (aref v (+ p 5)) #x2A))
           (%img-malformed))
         (values (logand (%img-u16le v (+ p 6)) #x3FFF) (logand (%img-u16le v (+ p 8)) #x3FFF)))
        (t
         (unless (and (>= len 5) (= (aref v p) #x2F)) (%img-malformed))
         (let ((bits (%img-u32le v (+ p 1))))
           (values (1+ (logand bits #x3FFF)) (1+ (logand (ash bits -14) #x3FFF)))))))

(defun %strip-webp (v)
  (let* ((n (length v))
         (riff-end (+ 8 (%img-u32le v 4)))
         (pos 12) (chunks '()) (orientation nil) (width nil) (height nil) (image nil))
    (unless (<= riff-end n) (%img-malformed))
    (loop while (< pos riff-end)
          do (unless (<= (+ pos 8) riff-end) (%img-malformed))
             (let* ((fourcc (map 'string #'code-char (subseq v pos (+ pos 4))))
                    (len (%img-u32le v (+ pos 4)))
                    (p (+ pos 8))
                    (end (+ p len)))
               (unless (<= end riff-end) (%img-malformed))
               ;; Wherever it appears: its flags byte is rewritten below.
               (when (and (string= fourcc "VP8X") (< len 10)) (%img-malformed))
               (when (and (null width) (member fourcc '("VP8X" "VP8 " "VP8L") :test #'string=))
                 (multiple-value-setq (width height) (%webp-size fourcc v p len)))
               (when (member fourcc '("VP8 " "VP8L" "ANMF") :test #'string=) (setf image t))
               (cond ((string= fourcc "EXIF")
                      ;; Some writers put the JPEG-style "Exif\0\0" before the TIFF header.
                      (let ((start (if (%img-ascii-at-p v p "Exif") (+ p 6) p)))
                        (setf orientation (or orientation (%exif-orientation v start end)))))
                     ((member fourcc +webp-kept-chunks+ :test #'string=)
                      (push (cons fourcc (subseq v p end)) chunks)))
               (setf pos (+ end (if (oddp len) 1 0)))))
    (unless (and image width height (plusp width) (plusp height)) (%img-malformed))
    (let* ((chunks (reverse chunks))
           (vp8x (assoc "VP8X" chunks :test #'string=))
           (exif (and vp8x orientation (/= orientation 1))))
      (when vp8x
        ;; Clear the EXIF (8) and XMP (4) flags, and set EXIF again for the new block.
        (let ((data (copy-seq (cdr vp8x))))
          (setf (aref data 0) (logior (logand (aref data 0) (lognot #x0C)) (if exif #x08 0)))
          (setf (cdr vp8x) data)))
      (let ((body (append (list (%img-ascii "WEBP"))
                          (loop for (fourcc . data) in chunks append (%webp-chunk fourcc data))
                          (when exif (%webp-chunk "EXIF" (%orientation-tiff orientation))))))
        (values (%img-concat (list* (%img-ascii "RIFF")
                                    (%img-le (reduce #'+ body :key #'length) 4)
                                    body))
                width height orientation)))))

;;; --- the format, from the bytes ----------------------------------------------

(defun strip-image-metadata (octets)
  "OCTETS, a JPEG, PNG or WebP image, with its metadata removed, as
(VALUES STRIPPED WIDTH HEIGHT CONTENT-TYPE EXTENSION) (#830).

The format is judged from the first bytes, never from a content type. The segments or chunks
that hold the pixels and say how to show them are copied byte for byte; everything else is
dropped, EXIF (GPS position, camera serial, thumbnail), XMP, IPTC, comments and text chunks
among it. When the original's EXIF Orientation is not 1, the result carries a new EXIF block
holding that field and nothing else. WIDTH and HEIGHT are as the image is shown: swapped when
Orientation turns it a quarter.

Signals BLOB-IMAGE-REFUSED: :UNSUPPORTED-FORMAT for anything else (SVG, GIF and HEIC
included), :MALFORMED for a file whose structure does not parse, and for any other error
while reading it."
  (let ((v (coerce octets '%image-octets)))
    (multiple-value-bind (strip content-type extension)
        (cond ((and (>= (length v) 3) (= (aref v 0) #xFF) (= (aref v 1) #xD8) (= (aref v 2) #xFF))
               (values #'%strip-jpeg "image/jpeg" "jpg"))
              ((and (>= (length v) 8) (every #'= +png-signature+ v))
               (values #'%strip-png "image/png" "png"))
              ((and (>= (length v) 12) (%img-ascii-at-p v 0 "RIFF") (%img-ascii-at-p v 8 "WEBP"))
               (values #'%strip-webp "image/webp" "webp"))
              (t (error 'blob-image-refused :reason :unsupported-format)))
      (multiple-value-bind (stripped width height orientation)
          ;; A backstop: an input the checks above did not foresee, which would otherwise end
          ;; in an index or type error the caller's fallback does not handle, is refused as
          ;; malformed like the ones they did.
          (handler-bind ((error (lambda (c)
                                  (unless (typep c 'blob-image-refused) (%img-malformed)))))
            (funcall strip v))
        (if (%turned-p orientation)
            (values stripped height width content-type extension)
            (values stripped width height content-type extension))))))

;;; --- the public copy -----------------------------------------------------------

(defun %public-image-dir (prefix bucket key)
  "Where the copies of BUCKET/KEY live: PREFIX, then the SHA-256 of bucket/key, then /. A hash,
so the public key does not show the private one."
  (format nil "~A~A/" prefix (%sha256-hex (format nil "~A/~A" bucket key))))

(defun %parse-copy-name (name)
  "A copy's name after its directory, VERSION-WxH.EXT, as (VALUES VERSION WIDTH HEIGHT EXT), or
NIL for a name of another shape."
  (let* ((dash (position #\- name))
         (x (and dash (position #\x name :start dash)))
         (dot (and x (position #\. name :start x))))
    (when dot
      (let ((width (ignore-errors (parse-integer name :start (1+ dash) :end x)))
            (height (ignore-errors (parse-integer name :start (1+ x) :end dot))))
        (when (and width height)
          (values (subseq name 0 dash) width height (subseq name (1+ dot))))))))

(defun %content-type-of (extension)
  (cdr (assoc extension '(("jpg" . "image/jpeg") ("png" . "image/png") ("webp" . "image/webp"))
              :test #'string=)))

(defun %read-image (store bucket key max-bytes)
  "The bytes of BUCKET/KEY, refusing :TOO-LARGE past MAX-BYTES."
  (with-blob-stream (in store bucket key)
    (let* ((buffer (make-array (1+ max-bytes) :element-type '(unsigned-byte 8)))
           (count (read-sequence buffer in)))
      ;; READ-SEQUENCE's count is what arrived; the size BLOB-METADATA reported is a claim.
      (when (> count max-bytes)
        (error 'blob-image-refused :bucket bucket :key key :reason :too-large
                                   :size count :limit max-bytes))
      (subseq buffer 0 count))))

(defun public-image-url (source-store bucket key public-store public-bucket
                         &key (prefix "og/") (max-bytes +default-max-image-bytes+)
                           (cache-control *public-image-cache-control*))
  "A permanent public URL for a copy of the image at BUCKET/KEY in SOURCE-STORE, with its
metadata removed, as (VALUES URL WIDTH HEIGHT CONTENT-TYPE) (#830).

The copy is written to PUBLIC-BUCKET in PUBLIC-STORE, a store the app configured as public
(:PUBLIC-BASE-URL, or :BASE-URL for the filesystem store), whose bucket lets anyone read an
object and nobody list them. Its key is PREFIX, the SHA-256 of bucket/key, then the SHA-256 of
the original's ETag with the width and height: og/<hash>/<hash>-1200x630.jpg. So:
  - a second call while the original is unchanged finds the copy by listing its directory, and
    reads and writes nothing;
  - a changed original has a new ETag, so it gets a new copy, and the older copies of the same
    image are deleted.

STRIP-IMAGE-METADATA says what is removed and what is refused. An image over MAX-BYTES is
refused too. Every refusal is BLOB-IMAGE-REFUSED, a BLOB-UNSUPPORTED, so the page falls back to
the site's image. The copy is written with CACHE-CONTROL.

The copy can be read by anyone who has its URL. Call this only for an image shown on a page
whose visibility is :PUBLIC, and call DELETE-PUBLIC-IMAGES when the image is deleted or its
page stops being public. Call it when the image is uploaded or replaced, and keep the URL,
width and height in the app's own row, rather than on every page view."
  (check-type prefix string)
  (check-type max-bytes (integer 1))
  (let* ((meta (blob-metadata source-store bucket key))
         (dir (%public-image-dir prefix bucket key))
         (bytes nil)
         (tag (or (blob-meta-etag meta) (blob-meta-checksum meta))))
    (when (and (blob-meta-size meta) (> (blob-meta-size meta) max-bytes))
      (error 'blob-image-refused :bucket bucket :key key :reason :too-large
                                 :size (blob-meta-size meta) :limit max-bytes))
    (unless tag
      ;; A source with neither an ETag nor a checksum is versioned by its bytes.
      (setf bytes (%read-image source-store bucket key max-bytes)
            tag (%sha256-hex bytes)))
    (let* ((version (%sha256-hex tag))
           (existing (list-blobs public-store public-bucket :prefix dir)))
      (dolist (k existing)
        (multiple-value-bind (v width height extension) (%parse-copy-name (subseq k (length dir)))
          (when (and v (string= v version) (%content-type-of extension))
            (return-from public-image-url
              (values (blob-url public-store public-bucket k) width height
                      (%content-type-of extension))))))
      (multiple-value-bind (stripped width height content-type extension)
          (handler-bind ((blob-image-refused
                           (lambda (c)
                             (unless (blob-error-key c)
                               (error 'blob-image-refused :bucket bucket :key key
                                                          :reason (blob-image-refused-reason c))))))
            (strip-image-metadata (setf bytes (or bytes (%read-image source-store bucket key max-bytes)))))
        (let ((copy (format nil "~A~A-~Dx~D.~A" dir version width height extension)))
          (put-blob public-store public-bucket copy (make-instance '%octet-source :octets stripped)
                    :content-type content-type :cache-control cache-control)
          (dolist (k existing)
            (unless (string= k copy)
              (delete-blob public-store public-bucket k)))
          (log:info "public image copy written" :bucket public-bucket :bytes (length stripped)
                                                :removed (- (length bytes) (length stripped)))
          (values (blob-url public-store public-bucket copy) width height content-type))))))

(defun delete-public-images (bucket key public-store public-bucket &key (prefix "og/"))
  "Delete every public copy PUBLIC-IMAGE-URL made of BUCKET/KEY, and return how many there were
(#830). Call it when the image is deleted, and when the page that shows it stops being public:
until then the copy stays readable by anyone with its URL. A crawler that already fetched the
image keeps its own copy whatever is deleted here, and a CDN in front of PUBLIC-STORE can serve
it until its Cache-Control max-age runs out."
  (let ((existing (list-blobs public-store public-bucket
                              :prefix (%public-image-dir prefix bucket key))))
    (dolist (k existing (length existing))
      (delete-blob public-store public-bucket k))))
