;;;; view-tests.lisp --- the launcher's ARGUMENT CONTRACT, asserted (pre-publication issue 276).
;;;;
;;;; hyperion-view is C++ and verify-tree neither compiles nor runs it, so before this
;;;; file a change to hyperion-view.cc moved NO check count in either direction -- the
;;;; gate was structurally blind to the one component every desktop app shells out to.
;;;; It had two open defects found by hand (pre-publication issue 268, #116) and zero tests, which is where the
;;;; third comes from.
;;;;
;;;; WHAT IS TESTED HERE IS THE CLI, NOT THE WINDOW, and that is deliberate rather than a
;;;; limitation accepted quietly. Opening a window needs a display, a window server and a
;;;; WebView2/WebKit runtime; asserting one needs a driver. None of that belongs in a gate
;;;; that has to run on three OSes and on a runner. But the ARGUMENT CONTRACT --
;;;; `URL [TITLE] [WIDTH] [HEIGHT] [--icon PATH]' -- is depended on by
;;;; hyperion/desktop:run-app and by consuming apps, is enforced by nothing else, and is
;;;; exercisable with no display at all. That is the part a gate can hold.
;;;;
;;;; The window half stays pre-publication issue 276's open remainder, and it is stated in the issue rather
;;;; than implied by this file's existence.
;;;;
;;;; SKIPS, NOT FAILURES, WHEN THE BINARY IS ABSENT. The launcher is build output: a fresh
;;;; checkout has no hyperion-view until someone runs build.{sh,ps1}. A red suite there
;;;; would train people to ignore it. FiveAM prints the skip and its reason, and
;;;; verify-tree surfaces skips rather than burying them (pre-publication issue 284's lesson, one file over) --
;;;; so "not built here" is visible rather than silent.
;;;;
;;;; A TEST THAT CREATES A WINDOW RUNS ONLY WHEN GITHUB_ACTIONS IS SET (#885). GitHub sets it on its
;;;; runners. CI is not enough: agents set CI=1 on developers' machines when they run suites, and
;;;; there a window would open on the developer's screen. Every such test checks
;;;; %REAL-WINDOW-ALLOWED-P and skips, naming GITHUB_ACTIONS, when it is false; and
;;;; %RUN-HIDDEN-LAUNCHER (Windows) and %RUN-SHOWN-LAUNCHER (macOS), the two functions here that
;;;; clear HYPERION_VIEW_NO_WINDOW, signal an error instead of starting the launcher, so a new test
;;;; that forgets the check fails rather than opening a window. Every other call runs with
;;;; HYPERION_VIEW_NO_WINDOW=1 (RUN-LAUNCHER).

(defpackage #:hyperion/view/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:desktop #:hyperion/desktop))
  (:export #:run-tests #:view))

(in-package #:hyperion/view/tests)

(def-suite view :description "hyperion-view: the argument contract, headless.")
(in-suite view)

(defparameter +budget+ 10
  "Seconds a CLI invocation may take before we call it hung.

pre-publication issue 268 was `--help' never exiting -- it fell through to the URL slot and webview_run()
blocked forever on a window. So EVERY invocation here is bounded, and a timeout is a
FAILURE rather than a hang: a test that waits forever for a launcher that waits forever
teaches nobody anything.")

(defun launcher ()
  "The launcher hyperion/desktop would actually use, or NIL.

Deliberately DESKTOP:DEFAULT-LAUNCHER rather than a path built here. A second copy of
`where is hyperion-view' is the producer/consumer defect this tree keeps finding -- if
resolution moves, this suite must move with it or say so."
  (ignore-errors
   (let ((p (desktop:default-launcher)))
     (and p (probe-file p)))))

(defun run-launcher (&rest args)
  "Run the launcher with ARGS under a timeout. Returns (values exit stdout stderr).

It runs with HYPERION_VIEW_NO_WINDOW=1, so a call that would create a window exits 3 instead
(#521). None of these calls is meant to create one, and on a developer's machine a test that
did would open a window on their screen. The real-window tests use %REPORT-PLACEMENT, which
clears the variable, or on macOS %RUN-SHOWN-LAUNCHER; both run only when GITHUB_ACTIONS is set
(#885)."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream))
        (previous (uiop:getenv "HYPERION_VIEW_NO_WINDOW")))
    (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") "1")
    (unwind-protect
         (handler-case
             (let ((code (nth-value
                          2 (uiop:run-program (cons (uiop:native-namestring (launcher)) args)
                                              :output out :error-output err
                                              :ignore-error-status t))))
               (values code (get-output-stream-string out) (get-output-stream-string err)))
           (error (e) (values :error (get-output-stream-string out) (princ-to-string e))))
      (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") (or previous "")))))

(defmacro with-launcher (&body body)
  `(let ((exe (launcher)))
     (if (null exe)
         (skip "hyperion-view is not built here -- run hyperion/hyperion-view/build.{sh,ps1}")
         (progn ,@body))))

(test the-resolution-rule-answers-without-erroring
  ;; DELIBERATELY NOT GUARDED BY WITH-LAUNCHER, and it is the reason this suite can sit in
  ;; the gate at all. verify-tree FAILS a suite that executes zero checks (pre-publication issue 116), and on a
  ;; machine that has never run build.{sh,ps1} every other test here skips -- so without
  ;; one unconditional check, adding this suite to the gate would turn a fresh checkout
  ;; red. This is that check, and it is not a formality: DEFAULT-LAUNCHER walks three
  ;; fallbacks and ends at a bare name, so "it answers something, and does not signal"
  ;; is a real property that a broken resolution rule would violate.
  (finishes (desktop:default-launcher))
  (is (not (null (desktop:default-launcher)))
      "default-launcher must always answer -- its last fallback is the bare name on PATH"))

(test the-launcher-is-where-desktop-looks-for-it
  ;; Not a tautology, and not the same as the test above: DEFAULT-LAUNCHER's last fallback
  ;; is a bare name, so it can answer with something that does not exist. PROBE-FILE is
  ;; the difference between "we have a rule" and "it is there".
  (with-launcher
    (is (probe-file exe) "default-launcher resolved to ~A, which is not a file" exe)))

(test help-prints-usage-and-exits
  ;; pre-publication issue 268, and the reason this suite exists at all. Before the fix: no --help handling,
  ;; so it became the URL, a window opened on a failed navigation, and the process never
  ;; returned. Measured on Windows: exited=FALSE after 5s, stdout empty, stderr empty.
  (with-launcher
    (dolist (flag '("--help" "-h"))
      (multiple-value-bind (code out err) (run-launcher flag)
        (is (eql 0 code) "~A must exit 0, got ~S (stderr: ~A)" flag code err)
        (is (search "usage:" out)
            "~A must print usage to STDOUT; got ~S" flag out)
        (is (search "--icon" out)
            "~A's usage must document --icon, which is part of the contract" flag)
        (is (zerop (length err)) "~A must not write to stderr; got ~S" flag err)))))

(test an-unknown-flag-is-refused-rather-than-retitling-the-window
  ;; The comment in main() claimed "an unrecognised flag must never silently become the
  ;; window title" while the code did exactly that -- any --flag fell into the positional
  ;; branch. A docstring-shaped claim in a comment, unchecked. This is the check.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "--bogus")
      (declare (ignore out))
      (is (eql 2 code) "an unknown option must exit 2, got ~S" code)
      (is (search "unknown option" err) "and say so on stderr; got ~S" err))))

(test a-trailing-icon-flag-is-refused-rather-than-becoming-the-title
  ;; The same defect's sharper case: `hyperion-view URL --icon' set the TITLE to the
  ;; literal string "--icon", because the i+1<argc guard fell through to the positional
  ;; branch rather than refusing.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "http://127.0.0.1:1/" "--icon")
      (declare (ignore out))
      (is (eql 2 code) "a trailing --icon must exit 2, got ~S" code)
      (is (search "--icon needs a path" err) "and say what is wrong; got ~S" err))))

(test surplus-arguments-are-refused
  ;; Four positionals is the contract. A fifth was silently dropped, so a caller that
  ;; added an argument got no signal that the launcher had not understood it.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "u" "t" "800" "600" "surplus")
      (declare (ignore out))
      (is (eql 2 code) "a fifth positional must exit 2, got ~S" code)
      (is (search "too many arguments" err) "and name it; got ~S" err))))

;;; --- the window icon a bundle carries (#74) ------------------------------------------
;;;
;;; These need no launcher binary: they check which file run-app would pass as --icon, using
;;; directories and files made here.

;;; --- where the window goes (#485) -------------------------------------------------
;;;
;;; On Windows the window used to open at the CW_USEDEFAULT cascade point, often partly below
;;; the work area. hyperion-view now centres it in the work area and shrinks it to fit
;;; (window-placement.h). --placement prints that arithmetic for given numbers without opening
;;; a window, so it is checked here on every OS. The numbers are work area left, top, right and
;;; bottom; client width and height in logical pixels; DPI; and what the frame adds.

(defun %placement (&rest numbers)
  "What `hyperion-view --placement NUMBERS' prints, as a list of four integers, or the exit
code when it did not exit 0."
  (multiple-value-bind (code out)
      (apply #'run-launcher "--placement" (mapcar #'princ-to-string numbers))
    (if (eql code 0)
        (mapcar #'parse-integer
                (uiop:split-string (string-trim '(#\Newline #\Return #\Space) out)))
        code)))

(test a-window-that-fits-is-centred-in-the-work-area
  (with-launcher
    ;; The display in #485: 2560x1600 at 150% (DPI 144), work area 1528 high, and a 1280x860
    ;; window, which is 1920x1290 at that DPI and 1936x1346 with its frame.
    (is (equal '(312 91 1936 1346) (%placement 0 0 2560 1528 1280 860 144 16 56))
        "the display from #485")
    ;; 100% scaling, a taskbar at the top: the work area starts at y 40.
    (is (equal '(352 140 1216 839) (%placement 0 40 1920 1080 1200 800 96 16 39)))
    ;; A second monitor to the left of the first: its work area has negative coordinates.
    (is (equal '(-1568 100 1216 839) (%placement -1920 0 0 1040 1200 800 96 16 39)))))

(test a-window-larger-than-the-work-area-is-shrunk-to-fit-it
  (with-launcher
    ;; Too tall at 150%: 1200 logical is 1800 physical, 1856 with the frame, in 1528.
    (is (equal '(312 0 1936 1528) (%placement 0 0 2560 1528 1280 1200 144 16 56)))
    ;; Too wide and too tall on a small screen.
    (is (equal '(0 0 1366 728) (%placement 0 0 1366 728 1920 1080 96 16 39)))))

(test a-window-on-a-mac-screen-is-placed-in-its-visible-frame
  ;; The numbers macOS's place_window passes (#485): points at DPI 96, which leaves them
  ;; unscaled, and y measured upwards, so the work area is the visible frame's left, bottom,
  ;; right and top. A 1512x982 screen with a 33-point menu bar and a 70-point Dock has the
  ;; visible frame 0,70 to 1512,949. webview_set_size makes the frame, title bar included,
  ;; WIDTH x HEIGHT, so a 1200x800 window has a 1200x772 client and a 28-point title bar.
  (with-launcher
    (is (equal '(156 109 1200 800) (%placement 0 70 1512 949 1200 772 96 0 28))
        "a window that fits is centred between the Dock and the menu bar")
    ;; 1000 points high, in 879: cut to 879 and put on the Dock.
    (is (equal '(116 70 1280 879) (%placement 0 70 1512 949 1280 972 96 0 28))
        "a window taller than the visible frame is cut to it")))

(test placement-refuses-what-is-not-nine-integers
  (with-launcher
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 144 16)) "eight numbers")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 144 16 56 7)) "ten numbers")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 "x" 16 56)) "a word in place of a number")
    ;; Out of range (review of train 22): strtol's ERANGE, and values whose product would
    ;; overflow a long in place_in_work_area. Run, like every call here, with
    ;; HYPERION_VIEW_NO_WINDOW=1; this mode creates no window in any case.
    (is (eql 2 (%placement 0 0 2560 1528 "99999999999999999999" 860 144 16 56))
        "a value past LONG_MAX")
    (is (eql 2 (%placement 0 0 2560 1528 2000000000 860 144 16 56))
        "a client width whose product with the DPI overflows a 32-bit long")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 2000000000 16 56)) "a DPI as large")
    (is (eql 2 (%placement -2000000 0 2560 1528 1280 860 144 16 56))
        "a coordinate more than a million pixels from the origin")
    (is (eql 2 (%placement 0 0 2560 1528 1280 860 0 16 56)) "a DPI of 0")
    (is (eql 2 (run-launcher "http://127.0.0.1:1/" "--placement"
                             "0" "0" "2560" "1528" "1280" "860" "144" "16" "56"))
        "a URL before it: --placement is a mode of its own, not an option of a window")))

(test hyperion-view-creates-no-window-when-told-not-to
  ;; The guard RUN-LAUNCHER relies on (#521): with HYPERION_VIEW_NO_WINDOW=1, a call that would
  ;; create a window exits 3 instead, and says why.
  (with-launcher
    (multiple-value-bind (code out err) (run-launcher "--report-placement" "800" "600")
      (declare (ignore out))
      (is (eql 3 code) "--report-placement under HYPERION_VIEW_NO_WINDOW=1 exits 3, got ~S" code)
      (is (search "HYPERION_VIEW_NO_WINDOW" err) "and names the variable: ~S" err))))

(test report-placement-refuses-what-is-not-two-positive-integers
  ;; Each of these is refused before webview_create, so no window is made on any OS. atoi read
  ;; "1280px" as 1280 and went on to create a window (review of train 21).
  (with-launcher
    (flet ((code (&rest args) (nth-value 0 (apply #'run-launcher "--report-placement" args))))
      (is (eql 2 (code "1280px" "860")) "a number with a suffix")
      (is (eql 2 (code "1280" "x")) "a word")
      (is (eql 2 (code "0" "860")) "zero")
      (is (eql 2 (code "-1280" "860")) "a negative number")
      (is (eql 2 (code "99999999999999999999" "860")) "a number past INT_MAX")
      (is (eql 2 (code "1280")) "one number")
      ;; A third value is a placement file (#485, part 2), so it would make a window; four are
      ;; refused before one is made.
      (is (eql 2 (code "1280" "860" "placement" "extra")) "four values"))))

(test exercise-placement-takes-one-path
  ;; Refused before webview_create, so no window is made on any OS. With one path it would make
  ;; a window, so under HYPERION_VIEW_NO_WINDOW=1 it exits 3 on Windows and macOS; on Linux the
  ;; mode is not supported and exits 1 before making one.
  (with-launcher
    (is (eql 2 (run-launcher "--exercise-placement")) "no path")
    (is (eql 2 (run-launcher "--exercise-placement" "a" "b")) "two paths")
    (is (eql #+(or win32 darwin) 3 #-(or win32 darwin) 1 (run-launcher "--exercise-placement" "a"))
        "one path: no window here")))

;;; --- the placement on a real window, on CI only (review of train 20) ----------------------
;;;
;;; --placement checks the arithmetic, but returns before a window exists. --report-placement
;;; creates the window, sizes and places it as a launch does, and prints what Windows reports.
;;; It is started hidden: Windows applies the starting process's hidden show state to the new
;;; process's first ShowWindow, so the window webview.h shows is not displayed. Even so it is a
;;; real window, so it runs only where the CI environment variable is set, on a runner, and not
;;; on a developer's machine.

(defun %real-window-allowed-p ()
  "True when a test may create a real window: only on a GitHub Actions runner, where GitHub sets
GITHUB_ACTIONS. CI is deliberately not read, because it is also set on developers' machines (#885)."
  (and (uiop:getenvp "GITHUB_ACTIONS") t))

(defun %run-hidden-launcher (&rest args)
  "Run `hyperion-view ARGS' started hidden, through PowerShell's Start-Process -WindowStyle
Hidden, with HYPERION_VIEW_NO_WINDOW cleared. Returns (values EXIT-CODE OUTPUT).

Signals an error, and starts nothing, unless %REAL-WINDOW-ALLOWED-P: with the variable cleared,
the launcher creates a window (#885)."
  (unless (%real-window-allowed-p)
    (error "%RUN-HIDDEN-LAUNCHER creates a window, and runs only when GITHUB_ACTIONS is set (#885)."))
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "hyperion-view-report-~36R/" (random (expt 2 40)))
                                (uiop:temporary-directory))))
         (out (merge-pathnames "out.txt" dir)))
    (flet ((quoted (text) (format nil "'~A'" (uiop:frob-substrings text '("'") "''"))))
      (ensure-directories-exist dir)
      (unwind-protect
           (let ((code (nth-value
                        2 (uiop:run-program
                           (list "pwsh" "-NoProfile" "-NonInteractive" "-Command"
                                 (format nil "Remove-Item Env:HYPERION_VIEW_NO_WINDOW -ErrorAction SilentlyContinue; $p = Start-Process -FilePath ~A -ArgumentList ~{~A~^,~} -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput ~A; exit $p.ExitCode"
                                         (quoted (uiop:native-namestring (launcher)))
                                         (mapcar #'quoted args)
                                         (quoted (uiop:native-namestring out))))
                           :output nil :error-output nil :ignore-error-status t))))
             (values code (if (probe-file out) (uiop:read-file-string out) "")))
        (ignore-errors (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))))

(defun %report-placement (width height &optional placement-file)
  "Run `hyperion-view --report-placement WIDTH HEIGHT [PLACEMENT-FILE]' hidden. Returns
(values EXIT-CODE OUTPUT)."
  (apply #'%run-hidden-launcher "--report-placement" (princ-to-string width) (princ-to-string height)
         (and placement-file (list (uiop:native-namestring placement-file)))))

(test the-window-is-placed-in-the-work-area-on-a-real-window
  "On a GitHub Actions Windows runner, a real window is placed where --placement says, inside the work area,
and Windows reports that rectangle."
  #-win32 (skip "The placement calls are Windows only")
  #+win32
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it creates a window")
        (multiple-value-bind (code out) (%report-placement 1280 860)
          (is (eql 0 code) "--report-placement exited ~S: ~A" code out)
          (let ((line (find-if (lambda (l) (uiop:string-prefix-p "work " l))
                               (uiop:split-string out :separator '(#\Newline #\Return)))))
            (is-true line "it printed a report: ~S" out)
            (when line
              (let* ((n (mapcar #'parse-integer
                                (remove-if-not (lambda (tok) (and (plusp (length tok))
                                                                  (or (digit-char-p (char tok 0))
                                                                      (char= (char tok 0) #\-))))
                                               (uiop:split-string line :separator '(#\Space)))))
                     (work (subseq n 0 4)) (dpi (nth 4 n)) (frame (subseq n 5 7))
                     (placement (subseq n 7 11)) (window (subseq n 11 15)))
                (is (equal placement (apply #'%placement (append work (list 1280 860 dpi) frame)))
                    "the real calls computed what --placement computes for the same numbers: ~S" line)
                (destructuring-bind (x y w h) placement
                  (is (equal window (list x y (+ x w) (+ y h)))
                      "Windows reports the window at the placement: ~S" line))
                (destructuring-bind (wl wt wr wb) work
                  (destructuring-bind (l tp r b) window
                    (is (and (<= wl l) (<= wt tp) (<= r wr) (<= b wb))
                        "and inside the work area: ~S" line))))))))))

;;; --- the same on a real macOS window, on a GitHub runner only (#485) ----------------------
;;;
;;; On macOS webview.h shows the window and activates the app as soon as it is created, and
;;; there is no hidden start, so this test shows a window. It runs only when GITHUB_ACTIONS is
;;; set. CI is not enough: agents set CI=1 when they run suites on a developer's machine, and
;;; that must not open a window there (#885).

(defun %run-shown-launcher (seconds &rest args)
  "Run `hyperion-view ARGS' with HYPERION_VIEW_NO_WINDOW cleared, so it creates a window, which
macOS shows. Returns (values EXIT-CODE OUTPUT), or :TIMEOUT when it is still running after
SECONDS; then that process, and nothing else, is killed.

Signals an error, and starts nothing, unless %REAL-WINDOW-ALLOWED-P, as %RUN-HIDDEN-LAUNCHER does
(#885)."
  (unless (%real-window-allowed-p)
    (error "%RUN-SHOWN-LAUNCHER creates a window, and runs only when GITHUB_ACTIONS is set (#885)."))
  (let ((previous (uiop:getenv "HYPERION_VIEW_NO_WINDOW"))
        (deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") "")
    (unwind-protect
         (let ((p (uiop:launch-program (cons (uiop:native-namestring (launcher)) args)
                                       :output :stream :error-output nil)))
           (unwind-protect
                (progn
                  (loop while (and (uiop:process-alive-p p) (< (get-internal-real-time) deadline))
                        do (sleep 0.1))
                  (if (uiop:process-alive-p p)
                      (progn (uiop:terminate-process p :urgent t)
                             (uiop:wait-process p)
                             (values :timeout ""))
                      (let ((out (uiop:slurp-stream-string (uiop:process-info-output p))))
                        (values (uiop:wait-process p) out))))
             (uiop:close-streams p)))
      (setf (uiop:getenv "HYPERION_VIEW_NO_WINDOW") (or previous "")))))

(test the-window-is-placed-in-the-visible-frame-on-a-real-mac-window
  "On a GitHub macOS runner, a real window is placed where --placement says, inside the screen's
visible frame, and a window taller than the screen is shrunk to the visible frame's height."
  #-darwin (skip "The macOS placement calls run on macOS only")
  #+darwin
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it shows a window")
        ;; webview_set_size makes the frame, title bar included, WIDTH x HEIGHT; the client is
        ;; that less the frame the report gives.
        (dolist (height '(860 5000))
          (multiple-value-bind (code out)
              (%run-shown-launcher 60 "--report-placement" "1280" (princ-to-string height))
            (is (eql 0 code) "--report-placement 1280 ~D exited ~S: ~A" height code out)
            ;; The work area (4), the DPI, the frame (2), the placement (4) and the window (4).
            (let* ((line (%report-line out "work "))
                   (n (and line (%report-numbers line))))
              (is (eql 15 (length n)) "it printed a report: ~S" out)
              (when (eql 15 (length n))
                (destructuring-bind (wl wb wr wt dpi fw fh x y w h l b r tp) n
                  (is (equal (list x y w h)
                             (%placement wl wb wr wt (- 1280 fw) (- height fh) dpi fw fh))
                      "the real calls computed what --placement computes: ~S" out)
                  (is (equal (list l b r tp) (list x y (+ x w) (+ y h)))
                      "macOS reports the window at the placement: ~S" out)
                  (is (and (<= wl l) (<= wb b) (<= r wr) (<= tp wt))
                      "and inside the visible frame: ~S" out)
                  (when (eql height 5000)
                    (is (eql h (- wt wb)) "a 5000-point window is cut to the visible frame: ~S"
                        out))))))))))

(defun %fresh-dir ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "hyperion-icon-~36R/" (random (expt 2 40) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun %touch (path)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string "icon" out))
  (probe-file path))

(test a-bundled-window-icon-is-found-beside-the-executable
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (progn
           (is (null (desktop:bundled-window-icon dir)) "no icon carried, so none found")
           (let ((icon (%touch (merge-pathnames "window-icon.png" dir))))
             (is (equal icon (desktop:bundled-window-icon dir)))))
      (aion/fs:delete-tree dir))))

(test the-bundled-icon-is-passed-before-the-callers-path
  ;; In a shipped app the caller's path is the build machine's. It exists on that machine,
  ;; so the bundled copy has to win even when the caller's file is present, or the icon
  ;; would depend on which machine the app runs on.
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (let ((bundled (%touch (merge-pathnames "window-icon.png" dir)))
               (callers (%touch (merge-pathnames "source-icon.png" dir))))
           (is (equal (list "--icon" (uiop:native-namestring bundled))
                      (hyperion/desktop::%icon-arguments callers bundled)))
           (is (equal (list "--icon" (uiop:native-namestring callers))
                      (hyperion/desktop::%icon-arguments callers nil))
               "without a bundled copy, the caller's existing file is used")
           (is (null (hyperion/desktop::%icon-arguments
                      (merge-pathnames "not-on-this-machine.png" dir) nil))
               "a caller's path that does not exist passes no --icon at all"))
      (aion/fs:delete-tree dir))))

#-win32
(test a-bundled-icon-behind-a-broken-link-is-not-found
  ;; A macOS .app keeps window-icon.png in Contents/Resources, with a symbolic link to it in
  ;; Contents/MacOS. If the file is gone, PROBE-FILE still returns the link, and the app passed
  ;; hyperion-view a path it cannot read instead of falling back to the caller's icon.
  (let ((dir (%fresh-dir)))
    (unwind-protect
         (let ((target (%touch (merge-pathnames "Resources-window-icon.png" dir)))
               (link (merge-pathnames "window-icon.png" dir))
               (callers (%touch (merge-pathnames "source-icon.png" dir))))
           (uiop:run-program (list "ln" "-s" (uiop:native-namestring target)
                                   (uiop:native-namestring link)))
           (is (equal target (desktop:bundled-window-icon dir))
               "through a link whose target exists, the target is found")
           (delete-file target)
           (is (probe-file link) "the precondition: PROBE-FILE still answers for the broken link")
           (is (null (desktop:bundled-window-icon dir)))
           (is (equal (list "--icon" (uiop:native-namestring callers))
                      (hyperion/desktop::%icon-arguments callers (desktop:bundled-window-icon dir)))
               "so the caller's icon is used instead"))
      (aion/fs:delete-tree dir))))

(test shipped-image-p-and-install-directory-answer-for-a-development-image
  "#416: hyperion/desktop's public answers are aion/platform's, and in this development SBCL the
image is not a shipped build and has no installation."
  (is-false (desktop:shipped-image-p))
  (is (null (desktop:install-directory)))
  (is (eq (desktop:shipped-image-p) (aion/platform:shipped-image-p)))
  (is (equal (desktop:install-directory) (aion/platform:shipped-image-directory))))

;;; --- the last placement, saved and restored (#485, part 2) -------------------------------
;;;
;;; --saved-placement prints the restore decision for a placement file and a work area, with no
;;; window, so the format and the rule are checked here on every OS. The restore and the save on
;;; a real window are checked on CI only, through --report-placement with a placement file.

(defun %write-placement (dir name text)
  "Write TEXT, exactly, to NAME in DIR; return the path."
  (let ((path (merge-pathnames name dir)))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(defun %saved-placement (path &rest work)
  "What `hyperion-view --saved-placement PATH WL WT WR WB' prints, trimmed, or the exit code
when it did not exit 0."
  (multiple-value-bind (code out)
      (apply #'run-launcher "--saved-placement" (uiop:native-namestring path)
             (mapcar #'princ-to-string work))
    (if (eql code 0) (string-trim '(#\Newline #\Return #\Space) out) code)))

(test a-saved-placement-is-used-only-when-it-is-well-formed-and-fits
  (with-launcher
    (let ((dir (%fresh-dir)))
      (unwind-protect
           (flet ((decide (text &rest work)
                    (apply #'%saved-placement (%write-placement dir "placement" text) work)))
             (is (equal "use 100 50 1380 910 0"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~%")
                                0 0 2560 1528))
                 "a placement inside the work area is used")
             (is (equal "use 100 50 1380 910 1"
                        (decide "hyperion-view-placement 1 100 50 1380 910 1" 0 0 2560 1528))
                 "with its maximised state, and without a newline")
             (is (equal "use 100 50 1380 910 0"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~C~C"
                                        #\Return #\Newline)
                                0 0 2560 1528))
                 "and with a CRLF")
             (is (equal "use -1800 100 -600 900 0"
                        (decide "hyperion-view-placement 1 -1800 100 -600 900 0" -1920 0 0 1040))
                 "on a monitor to the left, with negative coordinates")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 1380 910 0" 1920 0 3840 1040))
                 "not on a monitor that is no longer there")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 2000 50 2700 910 0" 0 0 2560 1528))
                 "not partly outside the work area")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 250 150 0" 0 0 2560 1528))
                 "not smaller than 200 by 150")
             ;; Each edge and each minimum on its own, so that removing any one check fails a
             ;; line here (review of #521: the bottom edge, the top edge and both minimums
             ;; could each be removed without a failure).
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 1380 1529 0" 0 0 2560 1528))
                 "not one pixel below the work area: the edge #485 is about")
             (is (equal "use 100 50 1380 1528 0"
                        (decide "hyperion-view-placement 1 100 50 1380 1528 0" 0 0 2560 1528))
                 "but touching the bottom edge is inside")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 -1 1380 910 0" 0 0 2560 1528))
                 "not one pixel above the work area")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -1 50 1380 910 0" 0 0 2560 1528))
                 "not one pixel left of the work area")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 2561 910 0" 0 0 2560 1528))
                 "not one pixel right of the work area")
             (is (equal "use 100 50 300 200 0"
                        (decide "hyperion-view-placement 1 100 50 300 200 0" 0 0 2560 1528))
                 "200 by 150 is large enough")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 299 200 0" 0 0 2560 1528))
                 "199 by 150 is not")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 100 50 300 199 0" 0 0 2560 1528))
                 "200 by 149 is not")
             ;; A window snapped to the left half: its rectangle includes invisible borders of 7
             ;; pixels left, right and below, so it passes the work area by that much (review of
             ;; #521). The borders are the last four values.
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -7 0 967 1535 0" 0 0 2560 1528))
                 "a snapped window is outside the work area when no borders are allowed for")
             (is (equal "use -7 0 967 1535 0"
                        (decide "hyperion-view-placement 1 -7 0 967 1535 0" 0 0 2560 1528 7 0 7 7))
                 "and inside it when its invisible borders are")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -8 0 967 1535 0" 0 0 2560 1528 7 0 7 7))
                 "but not one pixel further left than the border")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -7 0 967 1536 0" 0 0 2560 1528 7 0 7 7))
                 "nor one pixel further down")
             ;; Snapped on a 150% monitor, where the frame is 12 pixels and the invisible border
             ;; 11, and started from a 100% monitor, where they are 8 and 7. The borders are
             ;; measured on the window at 100%, so they are converted to the other monitor's
             ;; frame first (review of #521). The last two values are the two frame widths.
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -11 0 1431 1539 0" 0 0 3840 1528 7 0 7 7))
                 "a window snapped at 150% does not fit with the borders measured at 100%")
             (is (equal "use -11 0 1431 1539 0"
                        (decide "hyperion-view-placement 1 -11 0 1431 1539 0" 0 0 3840 1528 7 0 7 7 8 12))
                 "and fits once they are converted to the 150% frame")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -12 0 1431 1539 0" 0 0 3840 1528 7 0 7 7 8 12))
                 "but not one pixel past the converted border")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 0 -1 1431 1528 0" 0 0 3840 1528 7 0 7 7 8 12))
                 "and a side with no border, the top, gains none")
             (is (equal "ignore does-not-fit"
                        (decide "hyperion-view-placement 1 -8 0 967 1535 0" 0 0 2560 1528 11 0 11 11 12 8))
                 "converted the other way, from 150% to 100%, the border shrinks to 7")
             (dolist (text (list "junk"
                             "hyperion-view-placement 2 100 50 1380 910 0"
                             "hyperion-view-placement 1 100 50 1380 910 2"
                             "hyperion-view-placement 1 100 50 1380 910"
                             "hyperion-view-placement 1 100 50 1380 910 0 extra"
                             "hyperion-view-placement 1 100 50 1380px 910 0"
                             ;; Coordinates beyond a million pixels, where the subtractions in
                             ;; the fit check could overflow (review of train 22).
                             "hyperion-view-placement 1 -2147483648 50 2147483647 910 0"
                             ;; Fields not separated by a space, a tab between them, a plus sign
                             ;; (review of #521).
                             "hyperion-view-placement 1 100-50 1380 910 0"
                             (format nil "hyperion-view-placement 1 100 50~C1380 910 0" #\Tab)
                             "hyperion-view-placement 1 +100 50 1380 910 0"))
               (is (equal "ignore malformed" (decide text 0 0 2560 1528))
                   "not a malformed line: ~S" text))
             (is (equal "ignore malformed"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~%~Cjunk"
                                        (code-char 0))
                                0 0 2560 1528))
                 "not a valid line followed by a NUL and other bytes")
             (is (equal "ignore too-long"
                        (decide (format nil "hyperion-view-placement 1 100 50 1380 910 0~A junk"
                                        (make-string 300 :initial-element #\Space))
                                0 0 2560 1528))
                 "not a valid line followed by anything past 256 bytes (review of #521)")
             (is (equal "ignore unreadable"
                        (%saved-placement (merge-pathnames "absent" dir) 0 0 2560 1528))
                 "not a file that is not there")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560"))
                 "three numbers are refused")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560" "1528" "7" "0" "7"))
                 "seven numbers are refused")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560" "1528" "7" "0" "7" "101"))
                 "a border over 100 is refused")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560" "1528" "7" "0" "-1" "7"))
                 "a negative border is refused")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560" "1528" "7" "0" "7" "7" "8"))
                 "nine numbers are refused")
             (is (eql 2 (run-launcher "--saved-placement" "x" "0" "0" "2560" "1528" "7" "0" "7" "7" "8" "1001"))
                 "a frame width over 1000 is refused"))
        (aion/fs:delete-tree dir)))))

;;; --restore-placement prints where macOS puts a saved frame back, given the screens' visible
;;; frames, with no window, so the rule is checked here on every OS (#485). The frames are in
;;; Cocoa's coordinates, measured upwards, each as left, bottom, right, top. The visible frame
;;; 0 70 1512 949 is a 1512-point-wide screen less a Dock of 70 points and the menu bar.

(defun %restore-placement (path &rest screens)
  "What `hyperion-view --restore-placement PATH SCREENS' prints, trimmed, or the exit code when
it did not exit 0."
  (multiple-value-bind (code out)
      (apply #'run-launcher "--restore-placement" (uiop:native-namestring path)
             (mapcar #'princ-to-string screens))
    (if (eql code 0) (string-trim '(#\Newline #\Return #\Space) out) code)))

(test a-mac-restore-moves-the-frame-into-the-screen-it-overlaps-most
  (with-launcher
    (let ((dir (%fresh-dir)))
      (unwind-protect
           (flet ((restore (frame &rest screens)
                    (apply #'%restore-placement
                           (%write-placement dir "placement"
                                             (format nil "hyperion-view-placement 1 ~A~%" frame))
                           screens)))
             (is (equal "use 100 200 1300 900 0 screen 0"
                        (restore "100 200 1300 900 0" 0 70 1512 949))
                 "a frame inside the visible frame is used as it is")
             (is (equal "use 100 200 1300 900 1 screen 0"
                        (restore "100 200 1300 900 1" 0 70 1512 949))
                 "with its zoomed state")
             (is (equal "use 0 70 1512 949 0 screen 0"
                        (restore "-50 0 2000 1200 0" 0 70 1512 949))
                 "a frame larger than the screen is shrunk to the visible frame")
             (is (equal "use 712 200 1512 800 0 screen 0"
                        (restore "1000 200 1800 800 0" 0 70 1512 949))
                 "a frame partly off the right edge is moved left, by the least distance")
             (is (equal "use 0 200 800 800 0 screen 0"
                        (restore "-300 200 500 800 0" 0 70 1512 949))
                 "a frame partly off the left edge is moved right")
             (is (equal "use 100 70 900 570 0 screen 0"
                        (restore "100 0 900 500 0" 0 70 1512 949))
                 "a frame partly behind the Dock is moved up")
             (is (equal "use 100 349 900 949 0 screen 0"
                        (restore "100 400 900 1000 0" 0 70 1512 949))
                 "a frame partly behind the menu bar is moved down")
             (is (equal "use 1512 300 2512 900 0 screen 1"
                        (restore "1200 300 2200 900 0" 0 70 1512 949 1512 0 3432 1055))
                 "a frame across two screens goes to the one it overlaps most")
             (is (equal "use 600 100 1000 500 0 screen 0"
                        (restore "800 100 1200 500 0" 0 0 1000 800 1000 0 2000 800))
                 "when it overlaps two screens equally, the first is chosen")
             (is (equal "ignore off-screen"
                        (restore "2000 300 2800 900 0" 0 70 1512 949))
                 "a frame on a screen that is no longer there is ignored")
             (is (equal "ignore off-screen"
                        (restore "1512 200 2000 800 0" 0 70 1512 949))
                 "and so is one that only touches a screen's edge")
             (is (equal "use -1800 100 -600 900 0 screen 1"
                        (restore "-1800 100 -600 900 0" 0 70 1512 949 -1920 0 0 1055))
                 "on a screen to the left of the main screen, with negative x")
             (is (equal "use 100 -600 900 0 0 screen 1"
                        (restore "100 -300 900 300 0" 0 70 1512 949 -200 -1080 1720 0))
                 "on a screen below the main screen, with negative y, moved down into it")
             (is (equal "use 100 200 1300 900 0 screen 1"
                        (restore "100 200 1300 900 0" 0 0 0 0 0 70 1512 949))
                 "a screen with no area is passed over")
             (is (equal "ignore too-small"
                        (restore "100 200 299 400 0" 0 70 1512 949))
                 "a frame narrower than 200 is ignored")
             (is (equal "ignore too-small"
                        (restore "100 200 400 349 0" 0 70 1512 949))
                 "and one lower than 150")
             (is (equal "use 100 200 300 350 0 screen 0"
                        (restore "100 200 300 350 0" 0 70 1512 949))
                 "200 by 150 is large enough")
             (is (equal "ignore malformed"
                        (apply #'%restore-placement
                               (%write-placement dir "placement" "hyperion-view-placement 1 100 200")
                               '(0 70 1512 949)))
                 "a malformed line is ignored, as on Windows")
             (is (equal "ignore unreadable"
                        (%restore-placement (merge-pathnames "absent" dir) 0 70 1512 949))
                 "and so is a file that is not there")
             (let ((file (uiop:native-namestring
                          (%write-placement dir "valid" "hyperion-view-placement 1 100 200 1300 900 0"))))
               (is (eql 2 (run-launcher "--restore-placement" file)) "no screen is refused")
               (is (eql 2 (run-launcher "--restore-placement" file "0" "70" "1512"))
                   "three numbers are refused")
               (is (eql 2 (run-launcher "--restore-placement" file "0" "70" "1512" "949" "0"))
                   "five numbers are refused")
               (is (eql 2 (run-launcher "--restore-placement" file "0" "70" "1512" "x"))
                   "a word in place of a number is refused")
               (is (eql 2 (run-launcher "--restore-placement" file "0" "70" "1512" "1000001"))
                   "a coordinate over a million is refused")
               (is (eql 2 (apply #'run-launcher "--restore-placement" file
                                 (loop repeat 17 append (list "0" "70" "1512" "949"))))
                   "seventeen screens are refused")
               (is (equal "use 100 200 1300 900 0 screen 15"
                          (apply #'%restore-placement (merge-pathnames "valid" dir)
                                 (append (loop repeat 15 append (list 5000 5000 6000 6000))
                                         (list 0 70 1512 949))))
                   "and sixteen are taken")))
        (aion/fs:delete-tree dir)))))

(test placement-arguments-name-the-file-and-create-its-directory
  ;; %PLACEMENT-ARGUMENTS builds what run-app passes the launcher. This does not call run-app.
  (is (null (hyperion/desktop::%placement-arguments nil)) "no file, no arguments")
  (let* ((dir (%fresh-dir))
         (file (merge-pathnames "data/sub/window-placement" dir)))
    (unwind-protect
         (progn
           (is (equal (list "--placement-file" (uiop:native-namestring file))
                      (hyperion/desktop::%placement-arguments file)))
           (is-true (uiop:directory-exists-p (merge-pathnames "data/sub/" dir))
                    "and the file's directory now exists"))
      (aion/fs:delete-tree dir))))

(defun %report-numbers (line)
  "The integers in LINE, in order."
  (mapcar #'parse-integer
          (remove-if-not (lambda (tok) (and (plusp (length tok))
                                            (or (digit-char-p (char tok 0))
                                                (and (char= (char tok 0) #\-) (> (length tok) 1)))))
                         (uiop:split-string line :separator '(#\Space)))))

(defun %report-line (out prefix)
  (find-if (lambda (l) (uiop:string-prefix-p prefix l))
           (uiop:split-string out :separator '(#\Newline #\Return))))

(test a-real-window-is-restored-from-its-placement-file-and-saves-it
  "On a GitHub Actions Windows runner, a window opens at a saved placement that fits, writes it back, and
opens centred when the saved placement is on no monitor."
  #-win32 (skip "The placement calls are Windows only")
  #+win32
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it creates a window")
        (let ((dir (%fresh-dir)))
          (unwind-protect
               (let* ((work (multiple-value-bind (code out) (%report-placement 1280 860)
                              (declare (ignore code))
                              (let ((line (%report-line out "work ")))
                                (and line (subseq (%report-numbers line) 0 4)))))
                      (file (merge-pathnames "window-placement" dir)))
                 (is-true work "the work area was reported")
                 (when work
                   (destructuring-bind (wl wt wr wb) work
                     (declare (ignore wr wb))
                     (let* ((saved (list (+ wl 40) (+ wt 30) (+ wl 940) (+ wt 630)))
                            (text (format nil "hyperion-view-placement 1 ~{~D~^ ~} 0~%" saved)))
                       ;; A placement that fits is restored, and saved back unchanged.
                       (%write-placement dir "window-placement" text)
                       (multiple-value-bind (code out) (%report-placement 1280 860 file)
                         (is (eql 0 code) "--report-placement with a file exited ~S: ~A" code out)
                         (let ((line (%report-line out "restored ")))
                           (is-true line "the saved placement was restored: ~S" out)
                           (when line
                             (is (equal (append saved (list 0) saved) (%report-numbers line))
                                 "and Windows reports the window at it: ~S" line)))
                         (is-true (%report-line out "saved") "and it was saved: ~S" out))
                       (is (equal text (uiop:read-file-string file))
                           "the file holds the same placement")
                       ;; A placement on no monitor is ignored; the window is centred, and that is saved.
                       (%write-placement dir "window-placement"
                                         (format nil "hyperion-view-placement 1 -100000 -100000 -99000 -99300 0~%"))
                       (multiple-value-bind (code out) (%report-placement 1280 860 file)
                         (is (eql 0 code) "--report-placement exited ~S: ~A" code out)
                         (is-true (%report-line out "restore-ignored off-screen")
                                  "a placement on no monitor is ignored: ~S" out)
                         (let ((line (%report-line out "work ")))
                           (is-true line "and the window is placed as without a file: ~S" out)
                           (when line
                             (let ((window (subseq (%report-numbers line) 11 15)))
                               (is (equal (format nil "hyperion-view-placement 1 ~{~D~^ ~} 0~%" window)
                                          (uiop:read-file-string file))
                                   "and that placement is saved: ~S" line))))
                       ;; A file that cannot be written is reported, not silently skipped.
                       (multiple-value-bind (code out)
                           (%report-placement 1280 860 (merge-pathnames "no-such-dir/window-placement" dir))
                         (is (eql 1 code) "a placement file that cannot be written fails the mode: ~S ~A" code out)
                         (is-true (%report-line out "save-failed") "and says so: ~S" out)))))))
            (aion/fs:delete-tree dir))))))

(test the-placement-is-saved-while-the-window-is-open-and-a-maximised-start-is-maximised
  "On a GitHub Actions Windows runner, through --exercise-placement, which installs the window procedure a
launch installs: a move made with the move loop is saved with MAXIMIZED 0; maximising saves the
same rectangle with MAXIMIZED 1; restoring saves MAXIMIZED 0; minimising and then closing leaves
the file as it was. A start from a file that says MAXIMIZED 1 opens maximised (review of #521)."
  #-win32 (skip "The placement calls are Windows only")
  #+win32
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it creates a window, and shows it maximised")
        (let* ((dir (%fresh-dir))
               (file (merge-pathnames "window-placement" dir))
               (start '(50 50 650 500)))
          (unwind-protect
               (progn
                 (%write-placement dir "window-placement"
                                   (format nil "hyperion-view-placement 1 ~{~D~^ ~} 0~%" start))
                 (multiple-value-bind (code out)
                     (%run-hidden-launcher "--exercise-placement" (uiop:native-namestring file))
                   (is (eql 0 code) "--exercise-placement exited ~S: ~A" code out)
                   (is (equal "start-zoomed 0" (%report-line out "start-zoomed"))
                       "it started unmaximised: ~S" out)
                   (let* ((line (%report-line out "moved "))
                          (moved (and line (%report-numbers line))))
                     (is (= 4 (length moved)) "it reported where the move put the window: ~S" out)
                     (when (= 4 (length moved))
                       (is (not (equal moved start)) "and the move changed the rectangle: ~S" moved)
                       ;; The move made two size changes inside the move loop. Saving on each
                       ;; WM_SIZE there would write the same final rectangle, so only the count
                       ;; of writes tells the two apart (review of #521).
                       (is (equal "move-saves 1" (%report-line out "move-saves"))
                           "the move wrote the file once, when the move loop ended: ~S" out)
                       (flet ((saved (maximized)
                                (format nil "hyperion-view-placement 1 ~{~D~^ ~} ~D" moved maximized))
                              (after (step)
                                (let ((l (%report-line out (format nil "~A " step))))
                                  (and l (subseq l (1+ (length step)))))))
                         (is (equal (saved 0) (after "after-move"))
                             "the move was saved when the move loop ended: ~S" out)
                         (is (equal (saved 1) (after "after-maximize"))
                             "maximising saved the same rectangle, maximised: ~S" out)
                         (is (equal (saved 0) (after "after-restore"))
                             "restoring saved it unmaximised: ~S" out)
                         (is (equal (saved 0) (after "after-minimize-and-close"))
                             "minimising and closing left the file as it was: ~S" out)))))
                 (%write-placement dir "window-placement"
                                   (format nil "hyperion-view-placement 1 ~{~D~^ ~} 1~%" start))
                 (multiple-value-bind (code out)
                     (%run-hidden-launcher "--exercise-placement" (uiop:native-namestring file))
                   (is (eql 0 code) "--exercise-placement exited ~S: ~A" code out)
                   (is-true (%report-line out "restored ") "the saved placement was restored: ~S" out)
                   (is (equal "start-zoomed 1" (%report-line out "start-zoomed"))
                       "and a file saying MAXIMIZED 1 opened maximised: ~S" out)))
            (aion/fs:delete-tree dir))))))

;;; --- the last placement on a real macOS window, on a GitHub runner only (#485) -------------
;;;
;;; These show a window, as the macOS placement test above does, so they run only when
;;; GITHUB_ACTIONS is set (#885). The visible frame is read from a launch without a placement
;;; file, whose report starts with it.

(defun %mac-visible-frame ()
  "The visible frame of the screen a window opens on, as left, bottom, right, top, from
`--report-placement 1280 860' on a real window; or NIL."
  (multiple-value-bind (code out) (%run-shown-launcher 60 "--report-placement" "1280" "860")
    (let ((line (and (eql code 0) (%report-line out "work "))))
      (and line (subseq (%report-numbers line) 0 4)))))

(defun %placement-line (frame zoomed)
  (format nil "hyperion-view-placement 1 ~{~D~^ ~} ~D~%" frame zoomed))

(test a-real-mac-window-is-restored-into-the-visible-frame-and-saves-it
  "On a GitHub macOS runner: a saved frame inside the visible frame is restored as it is; one
partly off the screen is moved into it, where --restore-placement says; each is saved back; and
a frame on no screen is ignored, and the window is placed and saved as without a file."
  #-darwin (skip "The macOS placement calls run on macOS only")
  #+darwin
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it shows a window")
        (let ((dir (%fresh-dir))
              (work (%mac-visible-frame)))
          (unwind-protect
               (progn
                 (is-true work "the visible frame was reported")
                 (when work
                   (destructuring-bind (wl wb wr wt) work
                     (declare (ignore wt))
                     (let ((file (merge-pathnames "window-placement" dir)))
                       (flet ((restored (frame expected)
                                (%write-placement dir "window-placement" (%placement-line frame 0))
                                (multiple-value-bind (code out)
                                    (%run-shown-launcher 60 "--report-placement" "1280" "860"
                                                         (uiop:native-namestring file))
                                  (is (eql 0 code) "--report-placement with a file exited ~S: ~A"
                                      code out)
                                  (let ((line (%report-line out "restored ")))
                                    (is-true line "the saved frame was restored: ~S" out)
                                    (when line
                                      (is (equal (append expected (list 0) expected)
                                                 (%report-numbers line))
                                          "at ~S, and macOS reports the window there: ~S"
                                          expected line)))
                                  (is-true (%report-line out "saved") "and it was saved: ~S" out))
                                (is (equal (%placement-line expected 0)
                                           (uiop:read-file-string file))
                                    "the file holds the restored frame")))
                         (let ((inside (list (+ wl 40) (+ wb 30) (+ wl 940) (+ wb 630))))
                           (restored inside inside))
                         ;; Partly off the right edge: where --restore-placement puts it on this
                         ;; screen.
                         (let* ((off (list (- wr 300) (+ wb 30) (+ wr 600) (+ wb 630)))
                                (decision (apply #'%restore-placement
                                                 (%write-placement dir "decision"
                                                                   (%placement-line off 0))
                                                 work))
                                (expected (subseq (%report-numbers decision) 0 4)))
                           (is (not (equal off expected)) "the decision moved it: ~S" decision)
                           (restored off expected)))
                       (%write-placement dir "window-placement"
                                         (%placement-line '(-100000 -100000 -99000 -99300) 0))
                       (multiple-value-bind (code out)
                           (%run-shown-launcher 60 "--report-placement" "1280" "860"
                                                (uiop:native-namestring file))
                         (is (eql 0 code) "--report-placement exited ~S: ~A" code out)
                         (is-true (%report-line out "restore-ignored off-screen")
                                  "a frame on no screen is ignored: ~S" out)
                         (let ((line (%report-line out "work ")))
                           (is-true line "and the window is placed as without a file: ~S" out)
                           (when line
                             (is (equal (%placement-line (subseq (%report-numbers line) 11 15) 0)
                                        (uiop:read-file-string file))
                                 "and that frame is saved: ~S" line))))))))
            (aion/fs:delete-tree dir))))))

(test the-placement-is-saved-while-a-real-mac-window-is-open-and-a-zoomed-start-is-zoomed
  "On a GitHub macOS runner, through --exercise-placement, which installs the observer a launch
installs: a resize made between the live-resize notifications is saved once, when the live
resize ends; zooming saves the same frame with ZOOMED 1; unzooming saves ZOOMED 0; closing leaves
the file as it was. A start from a file that says ZOOMED 1 opens zoomed."
  #-darwin (skip "The macOS placement calls run on macOS only")
  #+darwin
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it shows a window")
        (let ((dir (%fresh-dir))
              (work (%mac-visible-frame)))
          (unwind-protect
               (progn
                 (is-true work "the visible frame was reported")
                 (when work
                   (let* ((file (merge-pathnames "window-placement" dir))
                          (start (list (+ (first work) 50) (+ (second work) 50)
                                       (+ (first work) 650) (+ (second work) 500))))
                     (%write-placement dir "window-placement" (%placement-line start 0))
                     (multiple-value-bind (code out)
                         (%run-shown-launcher 60 "--exercise-placement" (uiop:native-namestring file))
                       (is (eql 0 code) "--exercise-placement exited ~S: ~A" code out)
                       (is (equal "start-zoomed 0" (%report-line out "start-zoomed"))
                           "it started unzoomed: ~S" out)
                       (let* ((line (%report-line out "moved "))
                              (moved (and line (%report-numbers line))))
                         (is (= 4 (length moved)) "it reported where the resize put the window: ~S"
                             out)
                         (when (= 4 (length moved))
                           (is (not (equal moved start)) "and the resize changed the frame: ~S"
                               moved)
                           ;; Two frame changes between the live-resize notifications. Saving on
                           ;; each resize would write the same final frame, so only the count of
                           ;; writes tells the two apart, as on Windows.
                           (is (equal "move-saves 1" (%report-line out "move-saves"))
                               "the resize wrote the file once, when the live resize ended: ~S" out)
                           (is (equal "zoomed 1" (%report-line out "zoomed "))
                               "zoom: zoomed the window: ~S" out)
                           (flet ((saved (zoomed)
                                    (string-right-trim '(#\Newline) (%placement-line moved zoomed)))
                                  (after (step)
                                    (let ((l (%report-line out (format nil "~A " step))))
                                      (and l (subseq l (1+ (length step)))))))
                             (is (equal (saved 0) (after "after-move"))
                                 "the resize was saved when the live resize ended: ~S" out)
                             (is (equal (saved 1) (after "after-maximize"))
                                 "zooming saved the same frame, zoomed: ~S" out)
                             (is (equal (saved 0) (after "after-restore"))
                                 "unzooming saved it unzoomed: ~S" out)
                             (is (equal (saved 0) (after "after-close"))
                                 "closing left the file as it was: ~S" out)))))
                     (%write-placement dir "window-placement" (%placement-line start 1))
                     (multiple-value-bind (code out)
                         (%run-shown-launcher 60 "--exercise-placement" (uiop:native-namestring file))
                       (is (eql 0 code) "--exercise-placement exited ~S: ~A" code out)
                       (is-true (%report-line out "restored ") "the saved frame was restored: ~S"
                                out)
                       (is (equal "start-zoomed 1" (%report-line out "start-zoomed"))
                           "and a file saying ZOOMED 1 opened zoomed: ~S" out)))))
            (aion/fs:delete-tree dir))))))

(defun run-tests ()
  (let ((results (run 'view)))
    (explain! results)
    (unless (results-status results)
      (error "hyperion/view tests failed"))))

(test ci-alone-does-not-let-a-test-create-a-window
  "#885. With CI=1 and GITHUB_ACTIONS unset, which is how agents run suites on developers'
machines, no test may create a window: %REAL-WINDOW-ALLOWED-P is false, and %RUN-HIDDEN-LAUNCHER
signals an error before it starts the launcher. With GITHUB_ACTIONS set it is true. Both variables
are put back afterwards, so on a GitHub runner the real-window tests still run. Nothing here starts
the launcher, so it runs everywhere."
  (let ((ci (uiop:getenv "CI")) (gha (uiop:getenv "GITHUB_ACTIONS")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CI") "1"
                 (uiop:getenv "GITHUB_ACTIONS") "")
           (is (null (%real-window-allowed-p)) "CI=1 alone allowed a window")
           (signals error (%run-hidden-launcher "--report-placement" "800" "600"))
           (setf (uiop:getenv "GITHUB_ACTIONS") "true")
           (is-true (%real-window-allowed-p) "GITHUB_ACTIONS=true did not allow a window"))
      (setf (uiop:getenv "CI") (or ci "")
            (uiop:getenv "GITHUB_ACTIONS") (or gha "")))))

;;; --- native dialogs (#986): the checks on a page's call, with no window ---------------------
;;;
;;; `hyperion-view --dialog-request TOKEN PARAMS' runs the checks the binding runs on every call
;;; before a dialog is shown, and prints `ok KIND ...' or `refuse REASON'. They are the same on
;;; every OS, so these run everywhere.

(defun %dialog-request (token params)
  "The line `hyperion-view --dialog-request TOKEN PARAMS' prints. In PARAMS, ' stands for \"."
  (multiple-value-bind (code out)
      (run-launcher "--dialog-request" token (substitute #\" #\' params))
    (is (eql 0 code) "--dialog-request ~S ~S exited ~S" token params code)
    (string-right-trim '(#\Return #\Newline) out)))

(test a-dialog-call-without-the-launchs-token-is-refused-natively
  ;; The page's hyperionDialog holds the token in a closure. A script that calls the binding
  ;; another way, without it, is refused here, before anything else is read.
  (with-launcher
    (is (equal "ok open" (%dialog-request "t0k3n" "['t0k3n',1,{'kind':'open'}]")) "the token")
    (is (equal "refuse token" (%dialog-request "t0k3n" "['other',1,{'kind':'open'}]")) "another token")
    (is (equal "refuse token" (%dialog-request "t0k3n" "['',1,{'kind':'open'}]")) "an empty token")
    (is (equal "refuse token" (%dialog-request "t0k3n" "[{'kind':'open'},1]")) "no token at all")
    (is (equal "refuse token" (%dialog-request "t0k3n" "[1,1,{'kind':'open'}]")) "a number")
    (is (equal "refuse token" (%dialog-request "" "['',1,{'kind':'open'}]"))
        "a launch with no token refuses every call")))

(test a-good-dialog-request-is-read-whole
  (with-launcher
    (is (equal "ok save title=\"Save as\" folder=\"C:\\\\Users\" name=\"a.txt\" filter=\"Text\":*.txt;*.md filter=\"All files\":*"
               (%dialog-request "t" "['t',1,{'kind':'save','title':'Save as','folder':'C:\\\\Users','name':'a.txt','filters':[['Text','*.txt;*.md'],['All files','*']]}]")))
    (is (equal "ok open-many filter=\"Databases\":*.accdb;*.MDB"
               (%dialog-request "t" "['t',2,{'kind':'open-many','filters':[['Databases','*.accdb;*.MDB']]}]")))
    (is (equal "ok folder" (%dialog-request "t" "['t',123456789,{'kind':'folder'}]")))
    (is (equal "ok open title=\"a\\\"b\\\\c\""
               (%dialog-request "t" "['t',1,{'kind':'open','title':'a\\'b\\\\c'}]"))
        "a quote and a backslash in a title come through escaped once")))

(test each-bad-dialog-request-is-refused-with-its-reason
  (with-launcher
    (flet ((refused (reason request)
             (is (equal (format nil "refuse ~A" reason)
                        (%dialog-request "t" (format nil "['t',1,~A]" request)))
                 "~A for ~A" reason request)))
      (is (equal "refuse malformed" (%dialog-request "t" "{'kind':'open'}")) "not an array")
      (is (equal "refuse malformed" (%dialog-request "t" "['t',1,{'kind':'open'},1]")) "a third value")
      (is (equal "refuse malformed" (%dialog-request "t" "['t',1,'open']")) "a request that is not an object")
      (dolist (id '("" "0" "-1" "1.5" "'1'" "1234567890" "01" "true"))
        (is (equal "refuse id" (%dialog-request "t" (format nil "['t',~A{'kind':'open'}]"
                                                           (if (string= id "") "" (format nil "~A," id)))))
            "the call's id ~S" id))
      (refused "kind" "{}")
      (refused "kind" "{'kind':'delete'}")
      (refused "kind" "{'kind':1}")
      (refused "title" "{'kind':'open','title':'a\\u0001b'}")
      (refused "title" "{'kind':'open','title':'a\\tb'}")
      ;; A raw DEL, which is how JSON.stringify sends one, is refused before the title is checked:
      ;; webview.h's JSON reader does not return the request at all.
      (refused "malformed" (format nil "{'kind':'open','title':'a~Cb'}" (code-char 127)))
      (refused "title" (format nil "{'kind':'open','title':'~A'}" (make-string 201 :initial-element #\a)))
      (refused "folder" (format nil "{'kind':'open','folder':'~A'}" (make-string 4097 :initial-element #\a)))
      ;; A network share: opening the dialog there would send the user's credentials to its host.
      (refused "folder" "{'kind':'open','folder':'\\\\\\\\server\\\\share'}")
      (refused "folder" "{'kind':'open','folder':'//server/share'}")
      (refused "folder" "{'kind':'open','folder':'/\\\\server'}")
      (refused "name" "{'kind':'open','name':'a.txt'}")
      (refused "name" "{'kind':'save','name':'dir/a.txt'}")
      (refused "name" "{'kind':'save','name':'dir\\\\a.txt'}")
      (refused "filters" "{'kind':'folder','filters':[['All','*']]}")
      (refused "filters" "{'kind':'open','filters':'*.txt'}")
      (refused "filters" "{'kind':'open','filters':['*.txt']}")
      (refused "filters" "{'kind':'open','filters':[['All','*','x']]}")
      (refused "filters" (format nil "{'kind':'open','filters':[~{~A~^,~}]}"
                                 (loop repeat 33 collect "['All','*']")))
      (refused "filter-label" "{'kind':'open','filters':[['','*']]}")
      (refused "filter-label" "{'kind':'open','filters':[[1,'*']]}")
      (refused "filter-patterns" "{'kind':'open','filters':[['All','']]}")
      (refused "filter-patterns" (format nil "{'kind':'open','filters':[['Many','~{~A~^;~}']]}"
                                         (loop for i below 33 collect (format nil "*.e~D" i))))
      (dolist (pattern '("*." "a.txt" "*.t t" "*.*" "*.txt;" "*.12345678901234567"))
        (refused "pattern" (format nil "{'kind':'open','filters':[['Odd','~A']]}" pattern))))))

(test dialog-request-takes-a-token-and-params-and-nothing-else
  (with-launcher
    (is (eql 2 (run-launcher "--dialog-request" "t")) "no params")
    (is (eql 2 (run-launcher "--dialog-request" "t" "[]" "x")) "a third value")
    (is (eql 2 (run-launcher "http://127.0.0.1:1/" "--dialog-request" "t" "[]")) "after a URL")
    (is (eql 2 (run-launcher "--dialog-origin")) "--dialog-origin with no URL")))

(test the-dialogs-are-offered-to-the-origin-of-the-url-the-view-started-with
  (with-launcher
    (flet ((origin (url) (string-right-trim '(#\Return #\Newline)
                                            (nth-value 1 (run-launcher "--dialog-origin" url)))))
      (is (equal "http://127.0.0.1:8080" (origin "http://127.0.0.1:8080/app?x=1#y")))
      (is (equal "http://localhost:1" (origin "HTTP://LocalHost:1")))
      (is (equal "https://example.test" (origin "https://example.test?q")))
      (is (equal "" (origin "127.0.0.1:8080/")) "no scheme, no origin, so no dialogs"))))

(test exit-after-takes-seconds-from-1-to-3600
  (with-launcher
    (dolist (bad '("0" "3601" "x" "-1"))
      (is (eql 2 (run-launcher "http://127.0.0.1:1/" "--exit-after" bad)) "--exit-after ~A" bad))
    (is (eql 2 (run-launcher "http://127.0.0.1:1/" "--exit-after")) "--exit-after with nothing")
    (is (eql 3 (run-launcher "http://127.0.0.1:1/" "--dialogs" "--exit-after" "5"))
        "a good launch with --dialogs still makes no window under HYPERION_VIEW_NO_WINDOW=1")))

;;; --- native dialogs on a real window, on CI only (#986) ------------------------------------
;;;
;;; The view is started on a page served here, with --dialogs, and closes itself after a few
;;; seconds. The page and its frames report what they can see to /report on the server, and the
;;; test reads those requests.
;;;
;;; The first run checks: the app's top-level page has hyperionDialog and not the raw binding; a
;;; frame from another origin, a frame from the app's own origin, and a top-level page from another
;;; origin have neither; and a call made outside a user action is refused. No dialog is shown.
;;;
;;; The second run, on Windows only, sets HYPERION_VIEW_FAKE_DIALOG=1: a call needs no user action
;;; and is answered {"path":"fake-path"} three seconds later, from a timer, with no dialog shown. It
;;; checks: a direct call to the binding with the wrong token does not start a job, so the next
;;; real call gets the path rather than "busy"; a second call while the first is open gets "busy";
;;; and when the page goes to another origin while a call is open, the answer is not delivered
;;; there, even to a page that defines the functions an answer would be handed to.

(defun %percent-decode (text)
  (let ((octets (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop with i = 0 while (< i (length text))
          do (let ((c (char text i)))
               (cond ((and (char= c #\%) (<= (+ i 3) (length text)))
                      (vector-push-extend (parse-integer text :start (1+ i) :end (+ i 3) :radix 16)
                                          octets)
                      (incf i 3))
                     (t (vector-push-extend (char-code c) octets) (incf i)))))
    (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8))) :external-format :utf-8)))

(defparameter +dialog-send-js+
  "function send(k,v){return fetch('/report?'+k+'='+encodeURIComponent(v));}")

(defun %dialog-page (port path)
  "The HTML the test server answers for PATH. The app's origin is 127.0.0.1:PORT, and the other
origin is localhost:PORT."
  (flet ((reporter (key)
           (format nil "<!doctype html><script>~A send('~A',typeof window.hyperionDialog+','+typeof window.__hyperion_dialog_raw+','+location.origin);</script>" +dialog-send-js+ key)))
    (cond
      ;; The first run's top-level page.
      ((string= path "/")
       (format nil "<!doctype html><html><body><iframe src=\"http://localhost:~D/child\"></iframe><iframe src=\"/same\"></iframe><script>~A
var sent=send('top',typeof window.hyperionDialog+','+typeof window.__hyperion_dialog_raw+','+location.origin);
var noUser=(window.hyperionDialog?window.hyperionDialog({kind:'open'}):Promise.resolve({error:'absent'}))
.then(function(r){return send('nouser',JSON.stringify(r));});
Promise.all([sent,noUser]).then(function(){setTimeout(function(){location.href='http://localhost:~D/away';},1000);});
</script></body></html>" port +dialog-send-js+ port))
      ((string= path "/child") (reporter "child"))
      ((string= path "/same") (reporter "same"))
      ((string= path "/away") (reporter "away"))
      ;; The second run's page, under HYPERION_VIEW_FAKE_DIALOG=1.
      ((string= path "/fake")
       (format nil "<!doctype html><html><body><script>~A
window.external.invoke(JSON.stringify({id:1,method:'__hyperion_dialog_raw',params:['not-the-token',1,{kind:'open'}]}));
setTimeout(function(){
var a=window.hyperionDialog({kind:'open'});
var b=window.hyperionDialog({kind:'open'});
b.then(function(r){send('second',JSON.stringify(r));});
a.then(function(r){
send('first',JSON.stringify(r));
window.hyperionDialog({kind:'open'}).then(function(r){send('lost',JSON.stringify(r));});
setTimeout(function(){location.href='http://localhost:~D/trap';},200);
});
},500);
</script></body></html>" +dialog-send-js+ port))
      ;; A page on another origin that defines what an answer would be handed to, to catch one.
      ((string= path "/trap")
       (format nil "<!doctype html><script>~A
var rpc={nextSeq:1};for(var i=1;i<100;i++){rpc[i]={resolve:function(r){send('trap',JSON.stringify(r));},reject:function(r){send('trap',JSON.stringify(r));}};}
window._rpc=rpc;
try{Object.defineProperty(window,'__hyperion_dialog_reply',{value:function(id,r){send('trap',JSON.stringify(r));}});}catch(e){send('trap','could not define: '+e);}
send('trapready',location.origin);
</script>" +dialog-send-js+))
      (t nil))))

(defun %dialog-reports (server)
  "An alist of what the pages reported to SERVER, KEY to VALUE, oldest first."
  (loop for request in (reverse (aion/test-http:server-requests server))
        for path = (aion/test-http:request-path request)
        when (and (> (length path) 8) (string= "/report?" path :end2 8))
          collect (let* ((query (subseq path 8))
                         (eq (position #\= query)))
                    (cons (subseq query 0 eq) (%percent-decode (subseq query (1+ eq)))))))

(defmacro %with-dialog-server ((server port) &body body)
  "Run BODY with SERVER serving %DIALOG-PAGE on 127.0.0.1, and PORT its port."
  `(let ((,port nil))
     (aion/test-http:with-server
         (,server (lambda (request stream)
                    (let ((page (%dialog-page ,port (aion/test-http:request-path request))))
                      (if page
                          (aion/test-http:write-response
                           stream 200 '(("Content-Type" . "text/html; charset=utf-8")) page)
                          (aion/test-http:write-response stream 404 '() "")))))
       (setf ,port (aion/test-http:server-port ,server))
       ,@body)))

(defun %run-dialog-view (url)
  "Start the view on URL with --dialogs, closing itself after 20 seconds, as a real window: hidden
on Windows, shown on macOS. Returns its exit code."
  #+win32 (values (%run-hidden-launcher url "Dialogs" "--dialogs" "--exit-after" "20"))
  #+darwin (values (%run-shown-launcher 60 url "Dialogs" "--dialogs" "--exit-after" "20"))
  #-(or win32 darwin) (error "no real-window run for ~A here" url))

(test a-dialog-binding-reaches-only-the-apps-own-top-level-page-on-a-real-window
  "On a GitHub Actions runner, a real view started with --dialogs offers hyperionDialog to the app's
top-level page only, and refuses a call made outside a user action."
  #-(or win32 darwin) (skip "Linux shows no dialog yet, and its runner has no display for a window")
  #+(or win32 darwin)
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it creates a window")
        (%with-dialog-server (server port)
          (let* ((url (aion/test-http:server-url server "/"))
                 (app (subseq url 0 (1- (length url))))
                 (other (format nil "http://localhost:~D" port))
                 (code (%run-dialog-view url))
                 (reports (%dialog-reports server)))
            (flet ((report (key) (cdr (assoc key reports :test #'string=))))
              (is (eql 0 code) "the view exited ~S" code)
              (is (equal (format nil "function,undefined,~A" app) (report "top"))
                  "the app's page has hyperionDialog and not the raw binding: ~S" reports)
              (is (equal (format nil "undefined,undefined,~A" other) (report "child"))
                  "a frame from another origin has neither: ~S" reports)
              (is (equal (format nil "undefined,undefined,~A" app) (report "same"))
                  "a frame from the app's own origin has neither: ~S" reports)
              (is (equal "{\"error\":\"no-user-action\"}" (report "nouser"))
                  "a call outside a user action is refused: ~S" reports)
              (is (equal (format nil "undefined,undefined,~A" other) (report "away"))
                  "a top-level page from another origin has neither: ~S" reports)))))))

(test a-dialog-call-is-answered-once-at-a-time-and-only-to-the-apps-origin-on-a-real-window
  "On a GitHub Actions Windows runner, with HYPERION_VIEW_FAKE_DIALOG=1: a call without the token
starts nothing, a second call while one is open gets busy, and an answer is not delivered to a page
on another origin."
  #-win32 (skip "Only Windows answers a dialog call in this change; elsewhere every call is unavailable")
  #+win32
  (with-launcher
    (if (not (%real-window-allowed-p))
        (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it creates a window")
        (%with-dialog-server (server port)
          (let ((previous (uiop:getenv "HYPERION_VIEW_FAKE_DIALOG")))
            (setf (uiop:getenv "HYPERION_VIEW_FAKE_DIALOG") "1")
            (unwind-protect
                 (let* ((code (%run-dialog-view (aion/test-http:server-url server "/fake")))
                        (reports (%dialog-reports server)))
                   (flet ((report (key) (cdr (assoc key reports :test #'string=))))
                     (is (eql 0 code) "the view exited ~S" code)
                     (is (equal "{\"path\":\"fake-path\"}" (report "first"))
                         "the first call gets the path, so the call with the wrong token started no job: ~S"
                         reports)
                     (is (equal "{\"error\":\"busy\"}" (report "second"))
                         "a second call while the first is open gets busy: ~S" reports)
                     (is (equal (format nil "http://localhost:~D" port) (report "trapready"))
                         "the page on another origin loaded and set its traps: ~S" reports)
                     (is (null (report "trap"))
                         "and received no answer: ~S" reports)
                     (is (null (report "lost"))
                         "the call left behind is not answered either: ~S" reports)))
              (setf (uiop:getenv "HYPERION_VIEW_FAKE_DIALOG") (or previous ""))))))))
