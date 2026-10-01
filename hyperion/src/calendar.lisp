;;;; calendar.lisp --- a Monday-first month grid and a strip of consecutive days.
;;;;
;;;; Two Spinneret components and the pure date arithmetic they need. Dates are
;;;; "YYYY-MM-DD" strings and months are "YYYY-MM" strings throughout: they sort and
;;;; compare as dates, travel in query strings unchanged, and need no parsing by the
;;;; caller. Universal time is used only inside the arithmetic, always at noon UTC so
;;;; that adding days never crosses midnight.
;;;;
;;;; The components own layout only. What a day shows, and where a day or a month links
;;;; to, come from caller-supplied functions (RENDER-DAY, HREF-FOR-DAY, HREF-FOR-MONTH).
;;;; Month and weekday names come from a hyperion/i18n translation source, by default the
;;;; request's (HYPERION/I18N:*TRANSLATION-SOURCE*, #491), and fall back to built-in
;;;; English for a key the source does not have (HYPERION/I18N:TRANSLATION-EXISTS-P, #490).
;;;;
;;;; Contributed for #489 under the MIT licence, and adapted to the framework: the
;;;; original defined its own source variable and recognised a missing key by comparing
;;;; TRANSLATE's result with its "[section/key]" marker. Its stylesheet is
;;;; hyperion/assets/components/calendar.css, served by hyperion/assets as :calendar.

(cl:defpackage #:hyperion/calendar
  (:use #:cl)
  (:local-nicknames (#:spin #:spinneret)
                    (#:i18n #:hyperion/i18n)
                    (#:tz   #:aion/tz))
  (:documentation
   "A Monday-first month grid (MONTH-GRID) and a strip of N consecutive days
    (DAYS-STRIP), rendered with Spinneret, plus the pure date helpers behind them.
    Dates are YYYY-MM-DD strings, months YYYY-MM strings. Names are translated through
    a hyperion/i18n source under the :calendar section; the stylesheet is
    (hyperion/assets:url :calendar).")
  (:export
   ;; translation
   #:month-name #:month-title #:weekday-name
   ;; dates and months
   #:date-valid-p #:month-valid-p #:days-in-month #:add-days #:weekday #:weekend-p
   #:month-of #:month-step #:month-dates #:today
   ;; components
   #:month-grid #:days-strip))

(in-package #:hyperion/calendar)

;;; --- translation -------------------------------------------------------------

(defparameter +english+
  '(:calendar/month-1 "January" :calendar/month-2 "February" :calendar/month-3 "March"
    :calendar/month-4 "April" :calendar/month-5 "May" :calendar/month-6 "June"
    :calendar/month-7 "July" :calendar/month-8 "August" :calendar/month-9 "September"
    :calendar/month-10 "October" :calendar/month-11 "November"
    :calendar/month-12 "December"
    :calendar/weekday-1 "Mon" :calendar/weekday-2 "Tue" :calendar/weekday-3 "Wed"
    :calendar/weekday-4 "Thu" :calendar/weekday-5 "Fri" :calendar/weekday-6 "Sat"
    :calendar/weekday-7 "Sun"
    :calendar/month-year "{month} {year}"
    :calendar/previous-month "Previous month"
    :calendar/next-month "Next month")
  "The English text for every key this package looks up; used when there is no source,
or when the source has the key in neither the requested nor its default locale.")

(defun %key (prefix n)
  "The keyword :calendar/PREFIX-N."
  (intern (format nil "CALENDAR/~A-~D" prefix n) :keyword))

(defun %text (locale key source &rest args)
  "The text for KEY in LOCALE from SOURCE, with {named} ARGS interpolated; the English
default when SOURCE is NIL or has KEY in neither LOCALE nor its default locale."
  (if (and source (i18n:translation-exists-p source locale key))
      (apply #'i18n:translate source locale key args)
      (i18n:interpolate (getf +english+ key) args)))

(defun month-name (locale n &key (source i18n:*translation-source*))
  "The name of month N (1 = January .. 12) in LOCALE: key :calendar/month-N."
  (%text locale (%key "MONTH" n) source))

(defun weekday-name (locale n &key (source i18n:*translation-source*))
  "The short name of weekday N (1 = Monday .. 7 = Sunday) in LOCALE:
key :calendar/weekday-N."
  (%text locale (%key "WEEKDAY" n) source))

(defun month-title (locale month &key (source i18n:*translation-source*))
  "MONTH (YYYY-MM) as a heading in LOCALE, e.g. \"March 2027\": key :calendar/month-year,
with {month} and {year} interpolated."
  (%text locale :calendar/month-year source
         :month (month-name locale (parse-integer month :start 5 :end 7) :source source)
         :year (subseq month 0 4)))

;;; --- dates -------------------------------------------------------------------

(defun days-in-month (year month)
  "The number of days in MONTH (1-12) of YEAR, Gregorian leap years included."
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (and (zerop (mod year 4))
                (or (plusp (mod year 100)) (zerop (mod year 400))))
           29 28))))

(defun %parse-date (string)
  "The universal time at noon UTC on the date STRING (YYYY-MM-DD) names, or NIL when it
is not a real date between 1900 and 9999."
  (when (and (stringp string) (= (length string) 10)
             (char= (char string 4) #\-) (char= (char string 7) #\-))
    (let ((y (parse-integer string :start 0 :end 4 :junk-allowed t))
          (m (parse-integer string :start 5 :end 7 :junk-allowed t))
          (d (parse-integer string :start 8 :end 10 :junk-allowed t)))
      (when (and y m d (<= 1900 y 9999) (<= 1 m 12) (<= 1 d (days-in-month y m)))
        (encode-universal-time 0 0 12 d m y 0)))))

(defun %format-date (universal)
  "UNIVERSAL as a YYYY-MM-DD string, read in UTC."
  (multiple-value-bind (s mi h d m y) (decode-universal-time universal 0)
    (declare (ignore s mi h))
    (format nil "~4,'0D-~2,'0D-~2,'0D" y m d)))

(defun %require-date (date)
  (or (%parse-date date)
      (error "Not a YYYY-MM-DD date: ~S" date)))

(defun date-valid-p (string)
  "True when STRING is a real YYYY-MM-DD date."
  (and (%parse-date string) t))

(defun month-valid-p (string)
  "True when STRING is a real YYYY-MM month."
  (and (stringp string) (= (length string) 7)
       (date-valid-p (concatenate 'string string "-01"))))

(defun add-days (date n)
  "The date N days after DATE (before it, for a negative N)."
  (%format-date (+ (%require-date date) (* n 86400))))

(defun weekday (date)
  "DATE's day of the week, ISO numbering: 1 = Monday .. 7 = Sunday."
  (1+ (nth-value 6 (decode-universal-time (%require-date date) 0))))

(defun weekend-p (date)
  "True when DATE falls on a Saturday or a Sunday."
  (>= (weekday date) 6))

(defun month-of (date)
  "The month (YYYY-MM) DATE falls in."
  (subseq date 0 7))

(defun month-step (month n)
  "The month N months after MONTH (YYYY-MM); N may be negative."
  (let* ((y (parse-integer month :end 4))
         (m (parse-integer month :start 5 :end 7))
         (i (+ (* 12 y) (1- m) n)))
    (format nil "~4,'0D-~2,'0D" (floor i 12) (1+ (mod i 12)))))

(defun month-dates (month)
  "The dates a Monday-first grid of MONTH (YYYY-MM) shows: whole weeks, from the Monday on
or before the 1st to the Sunday on or after the last day. 28, 35 or 42 dates."
  (let* ((first (concatenate 'string month "-01"))
         (last (format nil "~A-~2,'0D" month
                       (days-in-month (parse-integer month :end 4)
                                      (parse-integer month :start 5 :end 7))))
         (start (add-days first (- 1 (weekday first))))
         (end (add-days last (- 7 (weekday last)))))
    (loop for d = start then (add-days d 1)
          collect d
          until (string= d end))))

(defun today (&key zone)
  "Today's date (YYYY-MM-DD). In UTC, or in ZONE (an IANA zone name such as
\"America/New_York\", or an aion/tz ZONE) when given."
  (let ((now (get-universal-time)))
    (%format-date (if zone (+ now (tz:offset zone now)) now))))

;;; --- components --------------------------------------------------------------
;;; Both write to SPINNERET:*HTML* as any WITH-HTML function does, so call them from
;;; inside a WITH-HTML body. RENDER-DAY is called for its output, not its value: it
;;; should write with SPINNERET:WITH-HTML, and whatever it returns is discarded.
;;; Class strings are built outside the markup forms, so the walker sees plain values.

(defun %day-class (base date &key month today)
  "BASE plus the modifier classes that apply to DATE."
  (format nil "~A~{ ~A~}" base
          (loop for (applies modifier) in `((,(and month (string/= (month-of date) month))
                                             "outside")
                                            (,(equal date today) "today")
                                            (,(weekend-p date) "weekend"))
                when applies collect (format nil "~A--~A" base modifier))))

(defun month-grid (locale month &key today render-day href-for-day href-for-month
                                     (source i18n:*translation-source*))
  "Render MONTH (YYYY-MM) as a Monday-first grid of whole weeks.

Above the grid: the month's title between previous and next links, whose hrefs are
(funcall HREF-FOR-MONTH month) for the adjacent months; with no HREF-FOR-MONTH the
title stands alone. Each cell shows its day number and then whatever
(funcall RENDER-DAY date) writes. When HREF-FOR-DAY is given, (funcall HREF-FOR-DAY
date) becomes a link stretched over the whole cell, beneath the day's content, so the
empty part of a cell is a target and links inside RENDER-DAY's output still work.

TODAY (YYYY-MM-DD, default (TODAY)) is marked cal-day--today; days outside MONTH are
marked cal-day--outside, Saturdays and Sundays cal-day--weekend. Returns NIL."
  (let ((today (or today (today)))
        (prev (month-step month -1))
        (next (month-step month 1)))
    (spin:with-html
      (:div :class "cal"
        (:div :class "cal-nav"
          (when href-for-month
            (:a :class "cal-nav__prev" :href (funcall href-for-month prev)
                :aria-label (%text locale :calendar/previous-month source) "‹"))
          (:strong :class "cal-nav__title" (month-title locale month :source source))
          (when href-for-month
            (:a :class "cal-nav__next" :href (funcall href-for-month next)
                :aria-label (%text locale :calendar/next-month source) "›")))
        (:div :class "cal-grid"
          (loop for n from 1 to 7
                do (:div :class (if (>= n 6) "cal-grid__head cal-grid__head--weekend"
                                    "cal-grid__head")
                     (weekday-name locale n :source source)))
          (dolist (date (month-dates month))
            (:div :class (%day-class "cal-day" date :month month :today today)
              (when href-for-day
                (:a :class "cal-day__open" :href (funcall href-for-day date)
                    :aria-label date))
              (:span :class "cal-day__num" (parse-integer date :start 8))
              (:div :class "cal-day__body"
                (when render-day
                  (progn (funcall render-day date) nil))))))))
    nil))

(defun days-strip (locale &key start (count 7) today render-day href-for-day
                               (source i18n:*translation-source*))
  "Render COUNT (default 7) consecutive days beginning at START (default TODAY), as a
row of cells. The window slides with START rather than snapping to a Monday, so the
weekend can fall anywhere in the row; Saturdays and Sundays are marked
cal-strip__day--weekend and TODAY (default (TODAY)) cal-strip__day--today.

Each cell is headed by its short weekday name and day number and then holds whatever
(funcall RENDER-DAY date) writes. With HREF-FOR-DAY the cell is a link to
(funcall HREF-FOR-DAY date) -- so RENDER-DAY's output should not itself contain links --
and without it a plain block. Returns NIL."
  (let* ((today (or today (today)))
         (start (or start today))
         (dates (loop for i below count collect (add-days start i))))
    (spin:with-html
      (:div :class "cal-strip"
        (dolist (date dates)
          (let ((class (%day-class "cal-strip__day" date :today today))
                (label (format nil "~A ~D"
                               (weekday-name locale (weekday date) :source source)
                               (parse-integer date :start 8))))
            (if href-for-day
                (:a :class class :href (funcall href-for-day date)
                  (:span :class "cal-strip__name" label)
                  (when render-day
                    (progn (funcall render-day date) nil)))
                (:div :class class
                  (:span :class "cal-strip__name" label)
                  (when render-day
                    (progn (funcall render-day date) nil))))))))
    nil))
