;;;; web-session.lisp --- the sessions a browser holds after exchanging a grant (#67)
;;;;
;;;; A page embedded on another site cannot rely on a cookie: browsers no longer send a
;;;; third-party cookie, or send it only partitioned. So the agent service gives the page an
;;;; opaque session id in exchange for a signed grant, the page keeps the id in memory, and it
;;;; sends it on every request as `Authorization: Session <id>'. A credential that the browser
;;;; does not send by itself cannot be used by a cross-site request forgery.
;;;;
;;;; The grant is short-lived (minutes), because it crosses the host page. The session lasts
;;;; as long as the application says: it ends when it has not been used for IDLE-SECONDS, or
;;;; MAX-SECONDS after it was opened, whichever comes first. To go on, the host mints a new
;;;; grant and the page exchanges it.
;;;;
;;;; Sessions are held in memory, in this process. A restart ends them all, and the page then
;;;; exchanges a new grant.
;;;;
;;;; A browser's EventSource cannot send an Authorization header, so a page that streams first
;;;; asks for a stream ticket with its session header, then opens the stream with the ticket in
;;;; the URL. A ticket can be used once, lasts TICKET-SECONDS (30 by default), and opens a
;;;; stream only while the session that asked for it is still open. A URL can reach a log; a
;;;; ticket in it has been spent, or has expired, before anyone could read the log and use it.

(defpackage #:praxeon/web-session
  (:use #:cl)
  (:export #:session-table #:session-table-p #:make-session-table
           #:session-table-idle-seconds #:session-table-max-seconds
           #:session-table-ticket-seconds
           #:open-session #:session-grant #:session-open-p #:close-session #:session-count
           #:issue-ticket #:redeem-ticket))

(in-package #:praxeon/web-session)

(defstruct (session-table (:constructor %make-session-table))
  "Open sessions by id, with the two limits on how long one lasts. CLOCK returns the time in
seconds; a test passes its own."
  (sessions (make-hash-table :test 'equal))
  (lock (sb-thread:make-mutex :name "praxeon-web-sessions"))
  (idle-seconds 1800 :type (integer 1))
  (max-seconds 43200 :type (integer 1))
  (ticket-seconds 30 :type (integer 1))
  (tickets (make-hash-table :test 'equal))  ; ticket -> (session-id . expires-at)
  (clock #'get-universal-time))

(defstruct (%session (:constructor %make-session (grant opened-at)))
  grant
  (opened-at 0 :type integer)
  (used-at 0 :type integer))

(defun make-session-table (&key (idle-seconds 1800) (max-seconds 43200) (ticket-seconds 30)
                                (clock #'get-universal-time))
  "An empty session table. A session ends after IDLE-SECONDS without a request (30 minutes by
default) or MAX-SECONDS after it was opened (12 hours by default). A stream ticket lasts
TICKET-SECONDS (30 by default)."
  (%make-session-table :idle-seconds idle-seconds :max-seconds max-seconds
                       :ticket-seconds ticket-seconds :clock clock))

(defun %expired-p (table session now)
  (or (>= (- now (%session-used-at session)) (session-table-idle-seconds table))
      (>= (- now (%session-opened-at session)) (session-table-max-seconds table))))

(defun %prune (table now)
  "Remove every expired session. Caller holds the lock."
  (let ((sessions (session-table-sessions table)))
    (loop for id being the hash-keys of sessions using (hash-value s)
          when (%expired-p table s now) collect id into gone
          finally (dolist (id gone) (remhash id sessions)))))

(defun open-session (table grant)
  "Open a session for GRANT, a verified grant, and return its id: 256 random bits as hex.
Expired sessions are removed first, so the table holds only sessions that can still be used."
  (let ((id (aion/random:random-hex 256))
        (now (funcall (session-table-clock table))))
    (sb-thread:with-mutex ((session-table-lock table))
      (%prune table now)
      (let ((s (%make-session grant now)))
        (setf (%session-used-at s) now
              (gethash id (session-table-sessions table)) s)))
    id))

(defun session-grant (table id)
  "The grant of session ID, or NIL when there is no such session or it has expired. A session
that is found counts as used now."
  (let ((now (funcall (session-table-clock table))))
    (sb-thread:with-mutex ((session-table-lock table))
      (let ((s (and (stringp id) (gethash id (session-table-sessions table)))))
        (cond ((null s) nil)
              ((%expired-p table s now)
               (remhash id (session-table-sessions table))
               nil)
              (t (setf (%session-used-at s) now)
                 (%session-grant s)))))))

(defun session-open-p (table id)
  "True when session ID is open in TABLE. Unlike SESSION-GRANT this does not count as using the
session, so a check made on a timer, such as an open stream's, does not keep an idle session
open. An expired session is removed."
  (let ((now (funcall (session-table-clock table))))
    (sb-thread:with-mutex ((session-table-lock table))
      (let ((s (and (stringp id) (gethash id (session-table-sessions table)))))
        (cond ((null s) nil)
              ((%expired-p table s now)
               (remhash id (session-table-sessions table))
               nil)
              (t t))))))

(defun issue-ticket (table id)
  "A stream ticket for session ID, 256 random bits as hex, or NIL when ID is not open. Asking
for one counts as using the session. Expired tickets are removed first."
  (when (session-grant table id)
    (let ((ticket (aion/random:random-hex 256))
          (now (funcall (session-table-clock table))))
      (sb-thread:with-mutex ((session-table-lock table))
        (let ((tickets (session-table-tickets table)))
          (loop for k being the hash-keys of tickets using (hash-value v)
                when (>= now (cdr v)) collect k into gone
                finally (dolist (k gone) (remhash k tickets)))
          (setf (gethash ticket tickets)
                (cons id (+ now (session-table-ticket-seconds table))))))
      ticket)))

(defun redeem-ticket (table ticket)
  "The session id TICKET was issued for, when TICKET has not been used, has not expired, and its
session is still open; otherwise NIL. TICKET cannot be used again either way."
  (let ((entry (and (stringp ticket)
                    (sb-thread:with-mutex ((session-table-lock table))
                      (let ((e (gethash ticket (session-table-tickets table))))
                        (remhash ticket (session-table-tickets table))
                        e)))))
    (when (and entry
               (< (funcall (session-table-clock table)) (cdr entry))
               (session-grant table (car entry)))
      (car entry))))

(defun close-session (table id)
  "End session ID. Returns true when there was one."
  (sb-thread:with-mutex ((session-table-lock table))
    (remhash id (session-table-sessions table))))

(defun session-count (table)
  "How many sessions TABLE holds, expired ones included until the next OPEN-SESSION."
  (sb-thread:with-mutex ((session-table-lock table))
    (hash-table-count (session-table-sessions table))))
