;;;; dates.lisp --- ISO 8601 dates in front matter, and the date formats feeds need (#353, #359).
;;;;
;;;; Front matter writes a date as ISO 8601: 2030-01-01, or 2030-01-01T09:00:00Z, or with an
;;;; offset such as +02:00. klio needs it as a universal time for two things: judging whether a
;;;; scheduled document is visible yet (#359), and dating feed entries (#353). A date with no
;;;; time is midnight UTC, and a time with no zone is UTC, so the same file means the same
;;;; instant on every server.
;;;;
;;;; Pure: no clock is read here.

(in-package #:klio)

(define-condition invalid-date (error)
  ((text :initarg :text :reader invalid-date-text)
   (field :initarg :field :initform nil :reader invalid-date-field))
  (:report (lambda (c s)
             (format s "klio: ~@[`~A' ~]~S is not an ISO 8601 date such as 2030-01-01 or 2030-01-01T09:00:00Z."
                     (invalid-date-field c) (invalid-date-text c)))))

(defun %digits (text start end)
  "The integer written in TEXT from START to END, all of it digits, or NIL."
  (and (<= end (length text))
       (< start end)
       (loop for i from start below end always (digit-char-p (char text i)))
       (parse-integer text :start start :end end)))

(defun parse-iso-date (text &key field)
  "TEXT, an ISO 8601 date or date and time, as a universal time. Signals INVALID-DATE, naming
FIELD, for anything else.

Accepted: YYYY-MM-DD; then optionally T or a space, HH:MM, optionally :SS, then optionally Z
or +HH:MM or -HH:MM. No zone means UTC."
  (flet ((bad () (error 'invalid-date :text text :field field)))
    (unless (stringp text) (bad))
    (let* ((text (string-trim " " text))
           (n (length text))
           (year (%digits text 0 4)) (month (%digits text 5 7)) (day (%digits text 8 10))
           (hour 0) (minute 0) (second 0) (offset 0))
      (unless (and year month day (>= n 10)
                   (char= #\- (char text 4)) (char= #\- (char text 7))
                   (<= 1 month 12) (<= 1 day 31))
        (bad))
      (let ((i 10))
        (when (< i n)
          (unless (member (char text i) '(#\T #\t #\Space)) (bad))
          (setf hour (%digits text (+ i 1) (+ i 3))
                minute (%digits text (+ i 4) (+ i 6)))
          (unless (and hour minute (> n (+ i 3)) (char= #\: (char text (+ i 3)))
                       (<= hour 23) (<= minute 59))
            (bad))
          (setf i (+ i 6))
          (when (and (< i n) (char= #\: (char text i)))
            (setf second (%digits text (+ i 1) (+ i 3)))
            (unless (and second (<= second 60)) (bad))
            (setf i (+ i 3)))
          (when (< i n)
            (case (char text i)
              ((#\Z #\z) (incf i))
              ((#\+ #\-)
               (let ((oh (%digits text (+ i 1) (+ i 3)))
                     (om (%digits text (+ i 4) (+ i 6))))
                 (unless (and oh om (char= #\: (char text (+ i 3))) (<= oh 23) (<= om 59)) (bad))
                 (setf offset (* (if (char= #\+ (char text i)) 1 -1) (+ (* oh 3600) (* om 60))))
                 (incf i 6)))
              (t (bad))))
          (unless (= i n) (bad))))
      (let ((time (handler-case (encode-universal-time (min second 59) minute hour day month year 0)
                    (error () (bad)))))
        ;; A time written with offset +02:00 is two hours ahead of UTC, so the instant is two
        ;; hours earlier than the same clock reading in UTC.
        (- time offset)))))

(defun date-universal-time (value &key field)
  "VALUE, a front-matter date, as a universal time: an integer is taken as one already, a
string is parsed by PARSE-ISO-DATE, and NIL stays NIL."
  (cond ((null value) nil)
        ((integerp value) value)
        (t (parse-iso-date value :field field))))

(defparameter +day-names+ #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
(defparameter +month-names+ #("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(defun rfc-822-date (universal-time)
  "UNIVERSAL-TIME as RSS 2.0 writes a date: Mon, 01 Jan 2030 09:00:00 GMT."
  (multiple-value-bind (s mi h d mo y dow) (decode-universal-time universal-time 0)
    (format nil "~A, ~2,'0D ~A ~D ~2,'0D:~2,'0D:~2,'0D GMT"
            (aref +day-names+ dow) d (aref +month-names+ (1- mo)) y h mi s)))

(defun rfc-3339-date (universal-time)
  "UNIVERSAL-TIME as Atom writes a date: 2030-01-01T09:00:00Z."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))
