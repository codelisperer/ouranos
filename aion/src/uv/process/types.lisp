;;;; types.lisp --- the typed core of aion/uv/process, in Coalton.
;;;;
;;;; ONE THING HERE IS LOAD-BEARING: how a child ended is a single fact that libuv
;;;; reports as TWO numbers, and reading either alone is wrong.
;;;;
;;;;   exit_status  the value the process passed to exit(), meaningful only if it
;;;;                actually called exit()
;;;;   term_signal  the signal that killed it, or 0 if none did
;;;;
;;;; A process killed by SIGKILL has an exit_status of ZERO. So the obvious check --
;;;; `(zerop status)` means success -- reports that a build which was killed mid-run
;;;; succeeded. That is the same shape of bug as treating end-of-stream as a failure in
;;;; aion/uv/net, and it gets the same treatment: an ADT in which the two cases cannot be
;;;; collapsed, and no way to ask about one without having been handed the other.
;;;;
;;;; The signal table is deliberately partial. Only signals whose NUMBER is the same on
;;;; Linux and macOS are named: SIGUSR1/SIGUSR2 (10/12 vs 30/31) and SIGCHLD (17 vs 20)
;;;; are omitted rather than given a number that is right on one platform and silently
;;;; wrong on the other -- the same reasoning that makes the rest of this binding classify
;;;; libuv errors by name instead of by errno.

(cl:in-package #:aion/uv/process/types)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- how a process ended ------------------------------------------------------

  (define-type Termination
    "How a child process ended. The two libuv numbers, read together."
    (Exited Integer)
    (Killed String))

  (declare decode-termination (Integer * Integer -> Termination))
  (define (decode-termination exit-status term-signal)
    "Decode libuv's (exit_status, term_signal) pair.

A non-zero term_signal wins: the process did not choose its exit status, it was killed,
and its status is meaningless."
    (if (== term-signal 0)
        (Exited exit-status)
        (Killed (signal-name term-signal))))

  (declare termination->string (Termination -> String))
  ;; NB the parameter is not named `t`: Coalton is case-insensitive, so `t` would be
  ;; CL:T -- a constant, not a binding.
  (define (termination->string outcome)
    (match outcome
      ((Exited status) (<> "exited-" (the String (into status))))
      ((Killed name) (<> "killed-" name))))

  (declare termination-tag (Integer * Integer -> String))
  (define (termination-tag exit-status term-signal)
    "CL-callable: the two raw numbers in, one rendered meaning out."
    (termination->string (decode-termination exit-status term-signal)))

  (declare terminated-well? (Integer * Integer -> Boolean))
  (define (terminated-well? exit-status term-signal)
    "CL-callable: did this process succeed?

True only for a process that CHOSE to exit, with status zero. A killed process is not a
success however tidy its exit status looks."
    (match (decode-termination exit-status term-signal)
      ((Exited status) (== status 0))
      ((Killed _) False)))

  ;;; --- signals --------------------------------------------------------------------

  (declare signal-name (Integer -> String))
  (define (signal-name n)
    "Name a signal number. Only the numbers that agree on Linux and macOS are named; an
unrecognised one is rendered rather than guessed at."
    (cond
      ((== n 1) "SIGHUP")
      ((== n 2) "SIGINT")
      ((== n 3) "SIGQUIT")
      ((== n 6) "SIGABRT")
      ((== n 9) "SIGKILL")
      ((== n 13) "SIGPIPE")
      ((== n 14) "SIGALRM")
      ((== n 15) "SIGTERM")
      ((== n 28) "SIGWINCH")
      (True (<> "signal-" (the String (into n))))))

  (declare signal-number (String -> Integer))
  (define (signal-number name)
    "The number for a signal named in lower case (\"term\", \"int\", ...).

Returns 0 for a name this table does not carry, which the CL shell turns into an error
rather than passing zero to kill(2) -- where it would mean \"check the process exists\"
and silently do nothing."
    (cond
      ((== name "hup") 1)
      ((== name "int") 2)
      ((== name "quit") 3)
      ((== name "abrt") 6)
      ((== name "kill") 9)
      ((== name "pipe") 13)
      ((== name "alrm") 14)
      ((== name "term") 15)
      ((== name "winch") 28)
      (True 0))))
