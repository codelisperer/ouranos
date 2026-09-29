;;;; tz.lisp --- a zone's UTC offset at an instant, and wall-clock time to UTC (#367).
;;;;
;;;; A consuming app lets a person set weekly hours in their own IANA zone ("weekdays 9 to 5",
;;;; Europe/Kyiv) and computes on the server the UTC instants those hours cover weeks ahead,
;;;; across daylight-saving changes. CL's ENCODE-UNIVERSAL-TIME takes a fixed offset only, and
;;;; nothing else in the tree knew a zone's rules.
;;;;
;;;; THE RULES ARE THE SYSTEM'S. A zone is read from its TZif file (RFC 8536) under $TZDIR, or
;;;; /usr/share/zoneinfo, and cached after the first read. A file holds the zone's transitions
;;;; up to some year and, from version 2, a footer: a POSIX TZ string such as
;;;; "EST5EDT,M3.2.0,M11.1.0" that gives the rule for every instant after the last transition.
;;;; A deployment image therefore needs the tzdata package. Windows has no such directory; there
;;;; a caller sets $TZDIR to a copy of the tz database, or gets UNKNOWN-ZONE.
;;;;
;;;; PURE BELOW THE LOOKUP. PARSE-TZIF turns bytes into a ZONE, and ZONE-OFFSET-AT and
;;;; ZONE-LOCAL-TO-UNIVERSAL are functions of a zone and numbers, so they are tested with
;;;; synthetic TZif bytes on every platform. Only FIND-ZONE and ZONE-NAMES read files.
;;;;
;;;; TIMES ARE CL UNIVERSAL TIMES, seconds since 1900-01-01 UTC, which the rest of the tree
;;;; uses. TZif counts from 1970, so the two differ by +UNIX-EPOCH+. Leap seconds are ignored:
;;;; the zones under right/ are the only ones that have them, and universal time has none.

(in-package #:aion/tz)

;;; --- conditions ----------------------------------------------------------------------

(define-condition tz-error (error) ()
  (:documentation "Root of the conditions aion/tz signals."))

(define-condition unknown-zone (tz-error)
  ((name :initarg :name :reader unknown-zone-name)
   (directory :initarg :directory :initform nil :reader unknown-zone-directory))
  (:report (lambda (c s)
             (format s "aion/tz: no time zone ~S in ~A. A zone is read from the tz database's TZif files; install the tzdata package, or set TZDIR to its directory."
                     (unknown-zone-name c) (or (unknown-zone-directory c) "the zone directory")))))

(define-condition invalid-zone-name (tz-error)
  ((name :initarg :name :reader invalid-zone-name-name))
  (:report (lambda (c s)
             (format s "aion/tz: ~S is not a zone name. A name is like \"Europe/Kyiv\": letters, digits, _ + - and /, not starting with / and without \"..\"."
                     (invalid-zone-name-name c)))))

(define-condition invalid-tzif (tz-error)
  ((reason :initarg :reason :reader invalid-tzif-reason))
  (:report (lambda (c s) (format s "aion/tz: not a usable TZif file: ~A" (invalid-tzif-reason c)))))

;;; --- civil dates ---------------------------------------------------------------------

(defconstant +unix-epoch+ 2208988800 "Universal time of 1970-01-01T00:00:00Z.")

(defun days-from-civil (year month day)
  "Days from 1970-01-01 to YEAR-MONTH-DAY in the proleptic Gregorian calendar."
  (let* ((y (if (<= month 2) (1- year) year))
         (era (floor y 400))
         (yoe (- y (* era 400)))
         (doy (+ (floor (+ (* 153 (+ month (if (> month 2) -3 9))) 2) 5) (1- day)))
         (doe (+ (* yoe 365) (floor yoe 4) (- (floor yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(defun civil-from-days (days)
  "(values year month day) for DAYS from 1970-01-01."
  (let* ((z (+ days 719468))
         (era (floor z 146097))
         (doe (- z (* era 146097)))
         (yoe (floor (- doe (floor doe 1460) (- (floor doe 36524)) (floor doe 146096)) 365))
         (doy (- doe (+ (* 365 yoe) (floor yoe 4) (- (floor yoe 100)))))
         (mp (floor (+ (* 5 doy) 2) 153))
         (day (1+ (- doy (floor (+ (* 153 mp) 2) 5))))
         (month (if (< mp 10) (+ mp 3) (- mp 9))))
    (values (+ yoe (* era 400) (if (<= month 2) 1 0)) month day)))

(defun %leap-year-p (y) (and (zerop (mod y 4)) (or (plusp (mod y 100)) (zerop (mod y 400)))))

(defun %weekday (days) "0 for Sunday, for DAYS from 1970-01-01, a Thursday." (mod (+ days 4) 7))

;;; --- the POSIX TZ string of a TZif footer ---------------------------------------------

(defstruct (posix-rule (:constructor %make-posix-rule))
  "A POSIX TZ string: the standard time's offset east of UTC and abbreviation, and, when the
zone has daylight saving, its offset and abbreviation and the two date rules with the seconds
after local midnight at which each change happens."
  std-offset std-abbrev dst-offset dst-abbrev start start-time end end-time)

(defun %tz-parse-error (string why)
  (error 'invalid-tzif :reason (format nil "footer ~S: ~A" string why)))

(defun parse-posix-tz (string)
  "STRING, a POSIX TZ string as in a TZif footer, as a POSIX-RULE. Signals INVALID-TZIF when it
is not one."
  (let ((i 0) (n (length string)))
    (labels ((peek () (and (< i n) (char string i)))
             (fail (why) (%tz-parse-error string why))
             (abbrev ()
               (if (eql (peek) #\<)
                   (let ((end (position #\> string :start i)))
                     (unless end (fail "an abbreviation opened with < is not closed"))
                     (prog1 (subseq string (1+ i) end) (setf i (1+ end))))
                   (let ((start i))
                     (loop while (and (peek) (alpha-char-p (peek))) do (incf i))
                     (when (< (- i start) 3) (fail "an abbreviation needs at least three letters"))
                     (subseq string start i))))
             (number (max)
               (let ((start i))
                 (loop while (and (peek) (digit-char-p (peek))) do (incf i))
                 (when (= start i) (fail "a number was expected"))
                 (let ((v (parse-integer string :start start :end i)))
                   (when (> v max) (fail (format nil "~D is out of range" v)))
                   v)))
             (hms (max-hours)
               ;; [+-]hh[:mm[:ss]], as seconds.
               (let ((sign (case (peek) (#\- (incf i) -1) (#\+ (incf i) 1) (t 1)))
                     (h (number max-hours)) (m 0) (s 0))
                 (when (eql (peek) #\:) (incf i) (setf m (number 59))
                   (when (eql (peek) #\:) (incf i) (setf s (number 59))))
                 (* sign (+ (* h 3600) (* m 60) s))))
             (date-rule ()
               (cond ((eql (peek) #\M)
                      (incf i)
                      (let ((m (number 12)))
                        (unless (eql (peek) #\.) (fail "M needs .week.day"))
                        (incf i)
                        (let ((w (number 5)))
                          (unless (eql (peek) #\.) (fail "M needs .week.day"))
                          (incf i)
                          (let ((d (number 6)))
                            (when (or (zerop m) (zerop w)) (fail "month and week count from 1"))
                            (list :m m w d)))))
                     ((eql (peek) #\J) (incf i) (list :j (number 365)))
                     (t (list :n (number 365)))))
             (rule-time ()
               ;; Version 3 allows hours from -167 to 167.
               (if (eql (peek) #\/) (progn (incf i) (hms 167)) 7200)))
      (let* ((std-abbrev (abbrev))
             (std (- (hms 24))))
        (if (null (peek))
            (%make-posix-rule :std-offset std :std-abbrev std-abbrev)
            (let* ((dst-abbrev (abbrev))
                   (dst (if (and (peek) (not (eql (peek) #\,))) (- (hms 24)) (+ std 3600))))
              (unless (eql (peek) #\,) (fail "a zone with daylight saving needs ,start,end rules"))
              (incf i)
              (let* ((start (date-rule)) (start-time (rule-time)))
                (unless (eql (peek) #\,) (fail "the end rule is missing"))
                (incf i)
                (let* ((end (date-rule)) (end-time (rule-time)))
                  (when (peek) (fail "something follows the end rule"))
                  (%make-posix-rule :std-offset std :std-abbrev std-abbrev
                                    :dst-offset dst :dst-abbrev dst-abbrev
                                    :start start :start-time start-time
                                    :end end :end-time end-time)))))))))

(defun %rule-day (rule year)
  "The day, counted from 1970-01-01, on which date RULE falls in YEAR."
  (ecase (first rule)
    (:j ;; Jn: 1 to 365, never counting 29 February.
     (let ((n (second rule)))
       (+ (days-from-civil year 1 1) (1- n)
          (if (and (%leap-year-p year) (>= n 60)) 1 0))))
    (:n ;; n: 0 to 365, counting 29 February.
     (+ (days-from-civil year 1 1) (second rule)))
    (:m ;; Mm.w.d: the w-th day d of month m, 5 meaning the last.
     (destructuring-bind (m w d) (rest rule)
       (let* ((first (days-from-civil year m 1))
              (day (+ first (mod (- d (%weekday first)) 7) (* 7 (1- w))))
              (next (if (= m 12) (days-from-civil (1+ year) 1 1) (days-from-civil year (1+ m) 1))))
         (loop while (>= day next) do (decf day 7))
         day)))))

(defun %rule-offset (rule unix)
  "(values offset abbreviation) that RULE gives at UNIX, seconds since 1970."
  (if (null (posix-rule-dst-abbrev rule))
      (values (posix-rule-std-offset rule) (posix-rule-std-abbrev rule))
      (let* ((std (posix-rule-std-offset rule))
             (dst (posix-rule-dst-offset rule))
             (year (nth-value 0 (civil-from-days (floor (+ unix std) 86400)))))
        ;; The year's two changes, as instants. The start is written in standard time and the
        ;; end in daylight time. The year is UNIX's year in standard local time. When the start
        ;; comes after the end in the year, as in the southern hemisphere, daylight time is the
        ;; part of the year outside the two.
        (flet ((in-dst-p (y)
                 (let ((start (- (+ (* 86400 (%rule-day (posix-rule-start rule) y))
                                    (posix-rule-start-time rule))
                                 std))
                       (end (- (+ (* 86400 (%rule-day (posix-rule-end rule) y))
                                  (posix-rule-end-time rule))
                               dst)))
                   (if (< start end)
                       (and (<= start unix) (< unix end))
                       ;; The southern hemisphere: daylight time spans the new year.
                       (or (< unix end) (<= start unix))))))
          (if (in-dst-p year)
              (values dst (posix-rule-dst-abbrev rule))
              (values std (posix-rule-std-abbrev rule)))))))

;;; --- TZif ----------------------------------------------------------------------------

(defstruct (zone (:constructor %make-zone (name transitions indexes types footer)))
  "A time zone as its TZif file gives it. TRANSITIONS is a vector of instants, seconds since
1970, and INDEXES the local time type in effect from each. TYPES is a vector of (offset dst-p
abbreviation). FOOTER is the POSIX-RULE for instants after the last transition, or NIL."
  name transitions indexes types footer)

(defun %be (octets start count &key signed)
  (let ((n 0))
    (dotimes (k count) (setf n (+ (* n 256) (aref octets (+ start k)))))
    (if (and signed (logbitp (1- (* 8 count)) n)) (- n (ash 1 (* 8 count))) n)))

(defun parse-tzif (octets &key (name nil))
  "OCTETS, the bytes of a TZif file (RFC 8536, versions 1 to 4), as a ZONE named NAME. From
version 2 the 64-bit data and the footer are used. Signals INVALID-TZIF when OCTETS are not a
TZif file."
  (let ((octets (coerce octets '(simple-array (unsigned-byte 8) (*))))
        (pos 0))
    (labels ((need (k) (when (> (+ pos k) (length octets))
                         (error 'invalid-tzif :reason "the file ends early")))
             (header ()
               (need 44)
               (unless (equalp (subseq octets pos (+ pos 4)) #(84 90 105 102)) ; "TZif"
                 (error 'invalid-tzif :reason "it does not start with TZif"))
               (let ((version (aref octets (+ pos 4))))
                 (prog1 (list version
                              (%be octets (+ pos 20) 4) (%be octets (+ pos 24) 4)
                              (%be octets (+ pos 28) 4) (%be octets (+ pos 32) 4)
                              (%be octets (+ pos 36) 4) (%be octets (+ pos 40) 4))
                   (incf pos 44))))
             (block-size (size counts)
               (destructuring-bind (isut isstd leap time type char) counts
                 (+ (* time size) time (* type 6) char (* leap (+ size 4)) isstd isut)))
             (data (size counts)
               (destructuring-bind (isut isstd leap time type char) counts
                 (declare (ignore isut isstd leap))
                 (need (block-size size counts))
                 (let* ((transitions (make-array time))
                        (indexes (make-array time))
                        (types (make-array type))
                        (tstart pos)
                        (istart (+ tstart (* time size)))
                        (ttstart (+ istart time))
                        (cstart (+ ttstart (* type 6))))
                   (dotimes (k time)
                     (setf (aref transitions k) (%be octets (+ tstart (* k size)) size :signed t)
                           (aref indexes k) (aref octets (+ istart k))))
                   (dotimes (k type)
                     (let* ((at (+ ttstart (* k 6)))
                            (desig (+ cstart (aref octets (+ at 5)))))
                       (setf (aref types k)
                             (list (%be octets at 4 :signed t)
                                   (plusp (aref octets (+ at 4)))
                                   (map 'string #'code-char
                                        (subseq octets desig
                                                (or (position 0 octets :start desig)
                                                    (+ cstart char))))))))
                   (when (zerop type) (error 'invalid-tzif :reason "it has no local time types"))
                   (when (some (lambda (i) (>= i type)) indexes)
                     (error 'invalid-tzif :reason "a transition names a local time type that does not exist"))
                   (incf pos (block-size size counts))
                   (values transitions indexes types)))))
      (destructuring-bind (version &rest counts) (header)
        (if (zerop version)
            (multiple-value-bind (tr ix ty) (data 4 counts)
              (%make-zone name tr ix ty nil))
            (progn
              (incf pos (block-size 4 counts))   ; the v1 block, which v2 repeats with 64 bits
              (destructuring-bind (v2 &rest counts2) (header)
                (declare (ignore v2))
                (multiple-value-bind (tr ix ty) (data 8 counts2)
                  (let* ((start (and (< pos (length octets)) (= 10 (aref octets pos)) (1+ pos)))
                         (end (and start (position 10 octets :start start)))
                         (text (and end (map 'string #'code-char (subseq octets start end)))))
                    (%make-zone name tr ix ty
                                (and text (plusp (length text)) (parse-posix-tz text))))))))))))

;;; --- the pure lookups ------------------------------------------------------------------

(defun %unix-offset (zone unix)
  "(values offset abbreviation dst-p) in ZONE at UNIX, seconds since 1970."
  (let* ((transitions (zone-transitions zone))
         (n (length transitions)))
    (flet ((type-values (k) (destructuring-bind (off dst abbrev) (aref (zone-types zone) k)
                              (values off abbrev dst))))
      (cond
        ((or (zerop n) (< unix (aref transitions 0)))
         (if (and (zerop n) (zone-footer zone))
             (%rule-offset (zone-footer zone) unix)
             (type-values 0)))
        ((and (zone-footer zone) (>= unix (aref transitions (1- n))))
         (%rule-offset (zone-footer zone) unix))
        (t
         ;; The last transition at or before UNIX.
         (let ((lo 0) (hi (1- n)))
           (loop while (< lo hi)
                 do (let ((mid (ceiling (+ lo hi) 2)))
                      (if (<= (aref transitions mid) unix) (setf lo mid) (setf hi (1- mid)))))
           (type-values (aref (zone-indexes zone) lo))))))))

(defun zone-offset-at (zone universal-time)
  "Seconds east of UTC in effect in ZONE at UNIVERSAL-TIME, and the zone's abbreviation then as
a second value."
  (multiple-value-bind (off abbrev) (%unix-offset zone (- universal-time +unix-epoch+))
    (values off abbrev)))

(defun zone-local-to-universal (zone year month day hour minute &optional (second 0))
  "The universal time at which ZONE's wall clocks show YEAR-MONTH-DAY HOUR:MINUTE:SECOND, and as a
second value which case applied:

  :UNIQUE   the time occurs once.
  :GAP      the time does not occur, because the clocks jumped over it (spring forward). The
            instant returned is the change itself, the first instant after the gap.
  :OVERLAP  the time occurs twice, because the clocks went back. The earlier instant is
            returned, and the later is the third value, so a caller can choose it instead."
  (let* ((local (+ (* 86400 (days-from-civil year month day)) (* 3600 hour) (* 60 minute) second))
         (offsets (remove-duplicates
                   (loop for probe in (list (- local 86400) local (+ local 86400))
                         collect (nth-value 0 (%unix-offset zone probe)))))
         (valid (sort (loop for o in offsets
                            for u = (- local o)
                            when (= o (nth-value 0 (%unix-offset zone u))) collect u)
                      #'<)))
    (cond
      ((= 1 (length valid)) (values (+ (first valid) +unix-epoch+) :unique nil))
      ((>= (length valid) 2)
       (values (+ (first valid) +unix-epoch+) :overlap (+ (car (last valid)) +unix-epoch+)))
      (t
       ;; A gap: between LOCAL read with the larger offset and with the smaller, the offset
       ;; changes once. The change is the first instant whose offset is the later one.
       (let* ((before (reduce #'min offsets))
              (after (reduce #'max offsets))
              (lo (- local after))
              (hi (- local before))
              (later (nth-value 0 (%unix-offset zone hi))))
         (loop while (< lo hi)
               do (let ((mid (floor (+ lo hi) 2)))
                    (if (= later (nth-value 0 (%unix-offset zone mid)))
                        (setf hi mid)
                        (setf lo (1+ mid)))))
         (values (+ lo +unix-epoch+) :gap nil))))))

;;; --- the system's zones ----------------------------------------------------------------

(defvar *tzdir* nil
  "The directory zones are read from, or NIL for $TZDIR, else /usr/share/zoneinfo/.")

(defun %tzdir ()
  (let ((dir (or *tzdir* (let ((env (uiop:getenv "TZDIR"))) (and env (plusp (length env)) env))
                 "/usr/share/zoneinfo/")))
    (uiop:ensure-directory-pathname dir)))

(defun %check-name (name)
  (unless (and (stringp name) (plusp (length name))
               (char/= (char name 0) #\/)
               (not (search ".." name))
               (every (lambda (ch) (or (alphanumericp ch) (find ch "/_+-"))) name))
    (error 'invalid-zone-name :name name))
  name)

(defvar *zones* (make-hash-table :test #'equal) "Zones read so far, by directory and name.")
(defvar *zones-lock* (sb-thread:make-mutex :name "aion-tz-zones"))

(defun find-zone (name)
  "The ZONE named NAME, such as \"Europe/Kyiv\", read from the zone directory the first time and
cached. Signals INVALID-ZONE-NAME for a name that could leave the directory, UNKNOWN-ZONE when
there is no such file, and INVALID-TZIF when the file is not one."
  (%check-name name)
  (let* ((dir (%tzdir))
         (key (cons (namestring dir) name)))
    (or (sb-thread:with-mutex (*zones-lock*) (gethash key *zones*))
        (let ((path (merge-pathnames (uiop:parse-unix-namestring name) dir)))
          (unless (uiop:file-exists-p path)
            (error 'unknown-zone :name name :directory (namestring dir)))
          (let ((zone (parse-tzif (with-open-file (in path :element-type '(unsigned-byte 8))
                                    (let ((v (make-array (file-length in)
                                                         :element-type '(unsigned-byte 8))))
                                      (subseq v 0 (read-sequence v in))))
                                  :name name)))
            (sb-thread:with-mutex (*zones-lock*) (setf (gethash key *zones*) zone)))))))

(defun %zone (zone) (if (zone-p zone) zone (find-zone zone)))

(defun offset (zone universal-time)
  "Seconds east of UTC in effect in ZONE, a zone name or a ZONE, at UNIVERSAL-TIME, and the
abbreviation as a second value."
  (zone-offset-at (%zone zone) universal-time))

(defun local-to-universal (zone year month day hour minute &optional (second 0))
  "The universal time of a wall-clock time in ZONE, a zone name or a ZONE; see
ZONE-LOCAL-TO-UNIVERSAL for the second and third values."
  (zone-local-to-universal (%zone zone) year month day hour minute second))

(defun valid-zone-p (name)
  "True when NAME is a zone the zone directory has."
  (handler-case (and (find-zone name) t)
    (tz-error () nil)))

(defun zone-names ()
  "Every zone name in the zone directory, sorted: each file under it that starts with TZif,
leaving out the posix/ and right/ copies. NIL when the directory does not exist."
  (let* ((dir (%tzdir))
         (names '()))
    (when (uiop:directory-exists-p dir)
      (labels ((walk (d prefix)
                 (dolist (f (uiop:directory-files d))
                   (when (with-open-file (in f :element-type '(unsigned-byte 8) :if-does-not-exist nil)
                           (and in (let ((b (make-array 4 :element-type '(unsigned-byte 8))))
                                     (and (= 4 (read-sequence b in)) (equalp b #(84 90 105 102))))))
                     (push (concatenate 'string prefix (file-namestring f)) names)))
                 (dolist (sub (uiop:subdirectories d))
                   (let ((last (car (last (pathname-directory sub)))))
                     (unless (and (string= prefix "") (member last '("posix" "right") :test #'string=))
                       (walk sub (concatenate 'string prefix last "/")))))))
        (walk dir "")))
    (sort names #'string<)))
