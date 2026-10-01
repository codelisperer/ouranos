;;;; calendar-tests.lisp --- hyperion/calendar against the real hyperion/i18n and aion/tz (#489).
;;;;
;;;; The contributed component had been run only against stand-ins for hyperion/i18n and
;;;; aion/tz. These tests load the real ones: translated names through a JSON dictionary
;;;; bound as the request's source (#491), the English fallback decided by
;;;; TRANSLATION-EXISTS-P (#490), and the markup the components write, read back from
;;;; Spinneret's output.

(cl:defpackage #:hyperion/calendar/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:cal #:hyperion/calendar)
                    (#:i18n #:hyperion/i18n)
                    (#:tz #:aion/tz)
                    (#:spin #:spinneret))
  (:export #:run-tests))

(in-package #:hyperion/calendar/tests)

(def-suite calendar :description "hyperion/calendar: dates, names and markup.")
(in-suite calendar)

(defun run-tests () (run! 'calendar))

(defun %ht (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun %source ()
  "German month names, a German heading order, one key whose text looks like a marker, and
no weekday names, so those fall back to English."
  (i18n:make-dictionary
   (%ht "de" (%ht "calendar" (%ht "month-3" "März" "month-12" "Dezember"
                                  "month-year" "{month} {year}"
                                  "next-month" "[calendar/next-month]"))
        "ja" (%ht "calendar" (%ht "month-3" "3月" "month-year" "{year}年{month}")))
   :default :de))

(defun %html (thunk)
  (let ((spin:*html-style* :tree))
    (spin:with-html-string (funcall thunk))))

;;; --- dates ---------------------------------------------------------------------

(test days-in-a-month-and-leap-years
  (is (= 31 (cal:days-in-month 2027 1)))
  (is (= 30 (cal:days-in-month 2027 4)))
  (is (= 28 (cal:days-in-month 2027 2)))
  (is (= 29 (cal:days-in-month 2028 2)))
  (is (= 28 (cal:days-in-month 1900 2)) "divisible by 100, not by 400")
  (is (= 29 (cal:days-in-month 2000 2)) "divisible by 400"))

(test dates-and-months-are-validated
  (is (cal:date-valid-p "2027-03-14"))
  (is (not (cal:date-valid-p "2027-02-29")))
  (is (cal:date-valid-p "2028-02-29"))
  (is (not (cal:date-valid-p "2027-3-14")))
  (is (not (cal:date-valid-p "1899-12-31")))
  (is (not (cal:date-valid-p nil)))
  ;; A digit followed by junk is not a number (review of #498).
  (is (not (cal:date-valid-p "2027-1x-14")))
  (is (not (cal:date-valid-p "2027-03-1a")))
  (is (not (cal:date-valid-p "20x7-03-14")))
  (is (not (cal:date-valid-p "2027-+3-14")))
  (is (not (cal:month-valid-p "2027-1x")))
  (is (cal:month-valid-p "2027-12"))
  (is (not (cal:month-valid-p "2027-13")))
  (signals error (cal:add-days "2027-02-30" 1))
  (signals error (cal:weekday "not a date")))

(test date-arithmetic
  (is (string= "2027-03-01" (cal:add-days "2027-02-28" 1)))
  (is (string= "2028-02-29" (cal:add-days "2028-02-28" 1)))
  (is (string= "2026-12-31" (cal:add-days "2027-01-01" -1)))
  (is (= 1 (cal:weekday "2027-03-15")) "a Monday")
  (is (= 7 (cal:weekday "2027-03-14")) "a Sunday")
  (is (cal:weekend-p "2027-03-13"))
  (is (not (cal:weekend-p "2027-03-12")))
  (is (string= "2027-03" (cal:month-of "2027-03-14")))
  (is (string= "2028-01" (cal:month-step "2027-12" 1)))
  (is (string= "2026-12" (cal:month-step "2027-01" -1)))
  (is (string= "2025-11" (cal:month-step "2027-01" -14))))

(test a-month-grid-shows-whole-weeks-from-monday
  "February 2021 starts on a Monday and has 28 days: 28 dates. March 2027 needs 35, and
August 2026 starts on a Saturday and has 31 days: 42."
  (is (= 28 (length (cal:month-dates "2021-02"))))
  (is (= 35 (length (cal:month-dates "2027-03"))))
  (is (= 42 (length (cal:month-dates "2026-08"))))
  (let ((dates (cal:month-dates "2027-03")))
    (is (= 1 (cal:weekday (first dates))))
    (is (= 7 (cal:weekday (car (last dates)))))
    (is (string= "2027-03-01" (first dates)) "1 March 2027 is a Monday")
    (is (string= "2027-04-04" (car (last dates))))))

(test today-in-a-zone
  "TODAY with a zone is the date there. Tokyo is UTC+9 all year, so its date is UTC's date
or the next one. Skipped where the host has no zone files (Windows)."
  (if (not (tz:valid-zone-p "Asia/Tokyo"))
      (skip "this host has no zone files for Asia/Tokyo")
      (let ((utc (cal:today)) (tokyo (cal:today :zone "Asia/Tokyo")))
        (is (cal:date-valid-p tokyo))
        (is (member tokyo (list utc (cal:add-days utc 1)) :test #'string=)))))

;;; --- names ---------------------------------------------------------------------

(test names-come-from-the-requests-source
  "Bound with WITH-TRANSLATION-SOURCE, as WRAP-TRANSLATION-SOURCE does per request (#491)."
  (i18n:with-translation-source ((%source))
    (is (string= "März" (cal:month-name :de 3)))
    (is (string= "März 2027" (cal:month-title :de "2027-03")))
    (is (string= "2027年3月" (cal:month-title :ja "2027-03")) "a locale can reorder the heading")))

(test a-key-the-source-lacks-falls-back-to-english
  "Weekday names are in neither locale of the source, so they are English. A month the
requested locale lacks comes from the source's default locale, not from English."
  (i18n:with-translation-source ((%source))
    (is (string= "Mon" (cal:weekday-name :de 1)))
    (is (string= "Dezember" (cal:month-name :ja 12)) "from the default locale")
    (is (string= "January" (cal:month-name :de 1)))))

(test a-translation-that-looks-like-a-marker-is-used
  "#490: the source's text for next-month is literally \"[calendar/next-month]\". The
contribution compared TRANSLATE's result with the marker and would have shown English here."
  (i18n:with-translation-source ((%source))
    (is (string= "[calendar/next-month]" (cal::%text :de :calendar/next-month i18n:*translation-source*)))))

(test with-no-source-the-names-are-english
  (let ((i18n:*translation-source* nil))
    (is (string= "March" (cal:month-name :de 3)))
    (is (string= "March 2027" (cal:month-title :de "2027-03")))
    (is (string= "Sun" (cal:weekday-name :de 7)))))

(test an-explicit-source-overrides-the-bound-one
  (i18n:with-translation-source (nil)
    (is (string= "März" (cal:month-name :de 3 :source (%source))))))

;;; --- markup --------------------------------------------------------------------

(defun %class-lists (html)
  "The classes of every element in HTML, one list per element. Spinneret quotes an attribute
value only when it needs to, so class=\"a b\" and class=a both occur."
  (loop with start = 0
        for pos = (search "class=" html :start2 start)
        while pos
        collect (let* ((from (+ pos 6))
                       (quoted (char= (char html from) #\"))
                       (begin (if quoted (1+ from) from))
                       (end (if quoted
                                (position #\" html :start begin)
                                (position-if (lambda (c) (member c '(#\Space #\Newline #\>))) html
                                             :start begin))))
                  (setf start end)
                  (uiop:split-string (subseq html begin end) :separator " "))))

(defun %with-class (class html)
  "How many elements in HTML carry CLASS."
  (count-if (lambda (classes) (member class classes :test #'string=)) (%class-lists html)))

(defun %count (needle haystack)
  (loop with start = 0 and n = 0
        for pos = (search needle haystack :start2 start)
        while pos do (incf n) (setf start (1+ pos))
        finally (return n)))

(test month-grid-writes-the-grid-and-its-navigation
  (let ((html (%html (lambda ()
                       (i18n:with-translation-source ((%source))
                         (cal:month-grid :de "2027-03"
                                         :today "2027-03-14"
                                         :href-for-month (lambda (m) (format nil "/cal?m=~A" m))
                                         :href-for-day (lambda (d) (format nil "/day/~A" d))
                                         :render-day (lambda (d)
                                                       (when (string= d "2027-03-10")
                                                         (spin:with-html
                                                           (:span :class "cal-item" "Dentist"))))))))))
    (is (search "März 2027" html))
    (is (search "href=\"/cal?m=2027-02\"" html))
    (is (search "href=\"/cal?m=2027-04\"" html))
    (is (= 35 (%with-class "cal-day" html)) "one cell per date")
    (is (= 1 (%with-class "cal-day--today" html)))
    (is (= 4 (%with-class "cal-day--outside" html)) "31 March is a Wednesday: 1 to 4 April")
    (is (= 10 (%with-class "cal-day--weekend" html)))
    (is (search "href=\"/day/2027-03-14\"" html))
    (is (search "Dentist" html))
    (is (= 7 (%with-class "cal-grid__head" html)))
    (is (= 2 (%with-class "cal-grid__head--weekend" html)))
    (is (search "aria-label=\"[calendar/next-month]\"" html))))

(test month-grid-without-month-links-shows-only-the-title
  (let ((html (%html (lambda () (cal:month-grid :en "2027-03" :today "2027-03-14")))))
    (is (search "March 2027" html))
    (is (not (search "cal-nav__prev" html)))
    (is (not (search "cal-day__open" html)))))

(test days-strip-slides-with-its-start
  "Seven days from a Thursday: the weekend sits in the middle, and the cells are links when
HREF-FOR-DAY is given."
  (let ((html (%html (lambda ()
                       (cal:days-strip :en :start "2027-03-11" :today "2027-03-12"
                                           :href-for-day (lambda (d) (format nil "/day/~A" d)))))))
    (is (= 7 (%with-class "cal-strip__day" html)))
    (is (= 2 (%with-class "cal-strip__day--weekend" html)))
    (is (= 1 (%with-class "cal-strip__day--today" html)))
    (is (search "Thu 11" html))
    (is (search "Wed 17" html))
    (is (search "href=\"/day/2027-03-17\"" html))))

;;; --- accessibility and the strip's width (review of #498) -------------------------

(defun %attr-count (attribute value html)
  "How many times ATTRIBUTE has VALUE in HTML, quoted or not."
  (+ (%count (format nil "~A=~A" attribute value) html)
     (%count (format nil "~A=\"~A\"" attribute value) html)))

(test today-is-marked-for-assistive-technology
  "aria-current=\"date\" on today's cell and no other, in the grid and in the strip."
  (let ((grid (%html (lambda () (cal:month-grid :en "2027-03" :today "2027-03-14"))))
        (strip (%html (lambda () (cal:days-strip :en :start "2027-03-11" :today "2027-03-12")))))
    (is (= 1 (%attr-count "aria-current" "date" grid)))
    (is (= 1 (%attr-count "aria-current" "date" strip)))))

(test each-day-carries-its-full-date-for-a-screen-reader
  "The grid shows a day as a column and a number, so each cell carries its full date: as
hidden text without day links, as the link's label with them. The weekday headers and the
bare numbers are hidden from screen readers, so nothing is read twice."
  (let ((plain (%html (lambda () (cal:month-grid :en "2027-03" :today "2027-03-14"))))
        (linked (%html (lambda () (cal:month-grid :en "2027-03" :today "2027-03-14"
                                                  :href-for-day (lambda (d) (format nil "/d/~A" d)))))))
    (is (= 35 (%with-class "cal-sr" plain)))
    (is (search "Sun 14 March 2027" plain))
    (is (search "aria-label=\"Sun 14 March 2027\"" linked))
    (is (= 0 (%with-class "cal-sr" linked)) "the link's label is the date; no second copy")
    (is (= 42 (%attr-count "aria-hidden" "true" plain)) "7 headers and 35 day numbers")))

(test the-strip-has-one-column-per-day
  "DAYS-STRIP gives the stylesheet its COUNT, so three days are three columns."
  (let ((html (%html (lambda () (cal:days-strip :en :start "2027-03-11" :count 3 :today "2027-03-12")))))
    (is (= 3 (%with-class "cal-strip__day" html)))
    (is (search "--cal-strip-count: 3" html))))

(defun %css-variables ()
  "The --cal-NAME: #hex; custom properties in calendar.css, as an alist."
  (let ((text (uiop:read-file-string
               (asdf:system-relative-pathname "hyperion" "assets/components/calendar.css")))
        (found '()))
    (loop with start = 0
          for pos = (search "--cal-" text :start2 start)
          while pos
          do (let* ((colon (position #\: text :start pos))
                    (semi (position #\; text :start pos))
                    (value (and colon semi (< colon semi)
                                (string-trim " " (subseq text (1+ colon) semi)))))
               (when (and value (plusp (length value)) (char= #\# (char value 0)))
                 (push (cons (subseq text (+ pos 6) colon) value) found))
               (setf start (1+ pos))))
    found))

(defun %luminance (hex)
  (flet ((channel (i)
           (let ((c (/ (parse-integer hex :start i :end (+ i 2) :radix 16) 255d0)))
             (if (<= c 0.03928d0) (/ c 12.92d0) (expt (/ (+ c 0.055d0) 1.055d0) 2.4d0)))))
    (+ (* 0.2126d0 (channel 1)) (* 0.7152d0 (channel 3)) (* 0.0722d0 (channel 5)))))

(defun %contrast (a b)
  (let ((la (%luminance a)) (lb (%luminance b)))
    (/ (+ (max la lb) 0.05d0) (+ (min la lb) 0.05d0))))

(test the-default-text-colours-meet-4.5-to-1
  "Every text colour the stylesheet declares, against every background it declares and
white, by WCAG's contrast formula, read from the shipped file (review of #498)."
  (let ((vars (%css-variables)))
    (dolist (fg '("text" "muted" "faint"))
      (dolist (bg '("head-bg" "outside-bg" "weekend-bg" "today-bg"))
        (let ((f (cdr (assoc fg vars :test #'string=)))
              (b (cdr (assoc bg vars :test #'string=))))
          (is (and f b (>= (%contrast f b) 4.5d0))
              "--cal-~A ~A on --cal-~A ~A: ~,2F" fg f bg b (and f b (%contrast f b)))))
      (let ((f (cdr (assoc fg vars :test #'string=))))
        (is (and f (>= (%contrast f "#ffffff") 4.5d0)) "--cal-~A ~A on white" fg f)))))
