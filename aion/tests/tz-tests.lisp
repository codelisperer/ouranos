;;;; tz-tests.lisp --- aion/tz (#367).
;;;;
;;;; Most checks run on TZif bytes built here, so they run on every platform, Windows included,
;;;; which has no zone directory. The checks against the system's own zones run where it has
;;;; them and skip, saying so, where it does not.

(cl:defpackage #:aion/tz/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:tz #:aion/tz))
  (:export #:run-tests))

(in-package #:aion/tz/tests)

(def-suite tz :description "Zone offsets and wall-clock times from TZif data (#367).")
(in-suite tz)

(defun run-tests () (run! 'tz))

;;; --- building TZif bytes -------------------------------------------------------------

(defun %be-bytes (n count)
  (let ((n (if (minusp n) (+ n (ash 1 (* 8 count))) n)))
    (loop for k from (1- count) downto 0 collect (ldb (byte 8 (* 8 k)) n))))

(defun %block (size types transitions chars desig)
  (append (loop for (at) in transitions append (%be-bytes at size))
          (loop for (nil index) in transitions collect index)
          (loop for (off dst) in types for d in desig
                append (append (%be-bytes off 4) (list (if dst 1 0) d)))
          chars))

(defun make-tzif (&key types transitions footer (version 2))
  "TZif bytes: TYPES is a list of (offset dst-p abbreviation), TRANSITIONS a list of (unix-time
type-index), FOOTER a POSIX TZ string or NIL. VERSION 0 writes a version 1 file."
  (let* ((desig '()) (chars '()))
    (dolist (ty types)
      (push (length chars) desig)
      (setf chars (append chars (map 'list #'char-code (third ty)) (list 0))))
    (setf desig (nreverse desig))
    (flet ((header (v)
             (append (map 'list #'char-code "TZif") (list v) (make-list 15 :initial-element 0)
                     (%be-bytes 0 4) (%be-bytes 0 4) (%be-bytes 0 4)
                     (%be-bytes (length transitions) 4) (%be-bytes (length types) 4)
                     (%be-bytes (length chars) 4))))
      (coerce (append (header (if (zerop version) 0 (+ 48 version)))
                      (%block 4 types transitions chars desig)
                      (unless (zerop version)
                        (append (header (+ 48 version))
                                (%block 8 types transitions chars desig)
                                (list 10) (map 'list #'char-code (or footer "")) (list 10))))
              '(vector (unsigned-byte 8))))))

(defun ut (y mo d h mi &optional (s 0))
  "The universal time of a UTC date and time."
  (encode-universal-time s mi h d mo y 0))

(defparameter +new-york+
  (tz:parse-tzif (make-tzif :types '((-18000 nil "EST")) :footer "EST5EDT,M3.2.0,M11.1.0")
                 :name "test/New_York")
  "New York's rule, from its footer alone.")

;;; --- the pure lookups ----------------------------------------------------------------

(test the-footer-rule-gives-new-york-s-offset-on-each-side-of-each-change
  (is (equal '(-18000 "EST") (multiple-value-list (tz:zone-offset-at +new-york+ (ut 2026 1 15 12 0)))))
  (is (equal '(-14400 "EDT") (multiple-value-list (tz:zone-offset-at +new-york+ (ut 2026 7 1 12 0)))))
  (is (= -18000 (tz:zone-offset-at +new-york+ (ut 2026 3 8 6 59 59))) "one second before the change")
  (is (= -14400 (tz:zone-offset-at +new-york+ (ut 2026 3 8 7 0 0))) "2:00 EST is 07:00Z")
  (is (= -14400 (tz:zone-offset-at +new-york+ (ut 2026 11 1 5 59 59))))
  (is (= -18000 (tz:zone-offset-at +new-york+ (ut 2026 11 1 6 0 0))) "2:00 EDT is 06:00Z"))

(test a-wall-clock-time-in-the-spring-gap-is-the-change-itself
  (multiple-value-bind (u kind) (tz:zone-local-to-universal +new-york+ 2026 3 8 2 30)
    (is (eq :gap kind))
    (is (= (ut 2026 3 8 7 0) u) "03:00 EDT, the first instant after the gap")))

(test a-wall-clock-time-in-the-autumn-overlap-is-the-earlier-with-the-later-beside-it
  (multiple-value-bind (u kind later) (tz:zone-local-to-universal +new-york+ 2026 11 1 1 30)
    (is (eq :overlap kind))
    (is (= (ut 2026 11 1 5 30) u) "01:30 EDT")
    (is (= (ut 2026 11 1 6 30) later) "and 01:30 EST an hour later")))

(test an-ordinary-wall-clock-time-occurs-once
  (multiple-value-bind (u kind) (tz:zone-local-to-universal +new-york+ 2026 5 4 9 0)
    (is (eq :unique kind))
    (is (= (ut 2026 5 4 13 0) u))))

(test half-hour-and-three-quarter-hour-offsets
  (let ((kolkata (tz:parse-tzif (make-tzif :types '((19800 nil "IST")) :footer "IST-5:30")))
        (kathmandu (tz:parse-tzif (make-tzif :types '((20700 nil "+0545")) :footer "<+0545>-5:45"))))
    (is (equal '(19800 "IST") (multiple-value-list (tz:zone-offset-at kolkata (ut 2026 6 1 0 0)))))
    (is (equal '(20700 "+0545") (multiple-value-list (tz:zone-offset-at kathmandu (ut 2026 6 1 0 0))))
        "a quoted abbreviation")
    (is (= (ut 2026 6 1 3 15) (tz:zone-local-to-universal kathmandu 2026 6 1 9 0)))))

(test transitions-are-used-up-to-the-last-and-the-footer-after-it
  "A zone with two explicit transitions in 1990 and a footer. Before the first, local time type 0
applies; between them, the transitions; after the last, the footer's rule, here Kyiv's."
  (let* ((t1 (- (ut 1990 7 1 0 0) (ut 1970 1 1 0 0)))
         (t2 (- (ut 1990 12 1 0 0) (ut 1970 1 1 0 0)))
         (zone (tz:parse-tzif
                (make-tzif :types '((10800 nil "MSK") (14400 t "MSD") (7200 nil "EET"))
                           :transitions (list (list t1 1) (list t2 2))
                           :footer "EET-2EEST,M3.5.0/3,M10.5.0/4"))))
    (is (= 10800 (tz:zone-offset-at zone (ut 1990 1 1 0 0))) "before the first transition")
    (is (= 14400 (tz:zone-offset-at zone (ut 1990 8 1 0 0))))
    (is (= 7200 (tz:zone-offset-at zone (ut 1990 12 15 0 0))) "the last transition's type")
    (is (equal '(10800 "EEST") (multiple-value-list (tz:zone-offset-at zone (ut 2040 7 1 0 0))))
        "far beyond the last transition, the footer")
    (is (= 7200 (tz:zone-offset-at zone (ut 2040 1 1 0 0))))))

(test the-southern-hemisphere-and-the-other-rule-forms
  (let ((sydney (tz:parse-tzif (make-tzif :types '((36000 nil "AEST"))
                                          :footer "AEST-10AEDT,M10.1.0,M4.1.0/3"))))
    (is (= 39600 (tz:zone-offset-at sydney (ut 2026 1 15 0 0))) "January is summer there")
    (is (= 36000 (tz:zone-offset-at sydney (ut 2026 7 15 0 0)))))
  (let ((j (tz:parse-tzif (make-tzif :types '((0 nil "AAA")) :footer "AAA0BBB,J60,J300")))
        (n (tz:parse-tzif (make-tzif :types '((0 nil "AAA")) :footer "AAA0BBB,59,300"))))
    ;; J60 is 1 March in every year; day 59 (from 0) is 29 February in a leap year.
    (is (= 0 (tz:zone-offset-at j (ut 2028 2 29 12 0))) "J never counts 29 February")
    (is (= 3600 (tz:zone-offset-at j (ut 2028 3 1 12 0))))
    (is (= 3600 (tz:zone-offset-at n (ut 2028 2 29 12 0))) "n does")))

(test a-rule-time-outside-the-day-is-read-as-version-3-allows
  ;; Changes at 25:00 local, the day after the date rule, and at -1:00, the day before.
  (let ((z (tz:parse-tzif (make-tzif :types '((0 nil "AAA")) :footer "AAA0BBB,M3.2.0/25,M11.1.0/-1"
                                     :version 3))))
    (is (= 0 (tz:zone-offset-at z (ut 2026 3 8 23 59))))
    (is (= 3600 (tz:zone-offset-at z (ut 2026 3 9 1 0))))
    (is (= 0 (tz:zone-offset-at z (ut 2026 11 1 0 0))) "-1:00 BBB on 1 November is 22:00Z the day before")))

(test a-version-1-file-and-bytes-that-are-not-tzif
  (let ((v1 (tz:parse-tzif (make-tzif :types '((3600 nil "CET")) :version 0))))
    (is (null (tz:zone-footer v1)))
    (is (= 3600 (tz:zone-offset-at v1 (ut 2026 1 1 0 0)))))
  (signals tz:invalid-tzif (tz:parse-tzif (coerce #(1 2 3) '(vector (unsigned-byte 8)))))
  (signals tz:invalid-tzif (tz:parse-tzif (make-tzif :types '((0 nil "X")) :footer "X0Y,M3")))
  (signals tz:invalid-tzif (tz:parse-posix-tz "EST5EDT")))

(test a-name-that-could-leave-the-zone-directory-is-refused
  (signals tz:invalid-zone-name (tz:find-zone "../../etc/passwd"))
  (signals tz:invalid-zone-name (tz:find-zone "/etc/localtime"))
  (signals tz:invalid-zone-name (tz:find-zone "Europe/Kyiv;rm"))
  (is (null (tz:valid-zone-p "../x"))))

(test a-zone-directory-given-by-the-caller-is-read-and-cached
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "aion-tz-~36R/" (random (expt 2 40) (make-random-state t)))
                                (uiop:temporary-directory))))
         (file (merge-pathnames "Test/Zone" dir)))
    (ensure-directories-exist file)
    (unwind-protect
         (progn
           (with-open-file (out file :direction :output :element-type '(unsigned-byte 8))
             (write-sequence (make-tzif :types '((19800 nil "IST")) :footer "IST-5:30") out))
           (let ((tz:*tzdir* (namestring dir)))
             (is (= 19800 (tz:offset "Test/Zone" (ut 2026 1 1 0 0))))
             (is (eq (tz:find-zone "Test/Zone") (tz:find-zone "Test/Zone")) "read once, then cached")
             (is (equal '("Test/Zone") (tz:zone-names)))
             (signals tz:unknown-zone (tz:find-zone "Test/Missing"))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;;; --- the system's zones ------------------------------------------------------------------

(defmacro with-system-zones (&body body)
  `(if (not (tz:valid-zone-p "America/New_York"))
       (skip "this system has no zone directory with America/New_York (install tzdata, or set TZDIR)")
       (progn ,@body)))

(test the-system-s-new-york-has-the-same-gap-and-overlap
  (with-system-zones
    (is (equal (list (ut 2026 3 8 7 0) :gap)
               (subseq (multiple-value-list (tz:local-to-universal "America/New_York" 2026 3 8 2 30)) 0 2)))
    (is (equal (list (ut 2026 11 1 5 30) :overlap (ut 2026 11 1 6 30))
               (multiple-value-list (tz:local-to-universal "America/New_York" 2026 11 1 1 30))))))

(test the-system-s-kyiv-kolkata-and-kathmandu
  (with-system-zones
    (let ((kyiv (if (tz:valid-zone-p "Europe/Kyiv") "Europe/Kyiv" "Europe/Kiev")))
      (is (= 7200 (tz:offset kyiv (ut 2026 1 15 12 0))))
      (is (= 10800 (tz:offset kyiv (ut 2026 7 15 12 0)))))
    (is (= 19800 (tz:offset "Asia/Kolkata" (ut 2026 7 15 12 0))))
    (is (= 20700 (tz:offset "Asia/Kathmandu" (ut 2026 7 15 12 0))))
    (is (member "America/New_York" (tz:zone-names) :test #'string=))
    (is (not (member "posix/America/New_York" (tz:zone-names) :test #'string=)))))
