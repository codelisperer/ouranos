;;;; drain.lisp --- measure what each backend does with requests on SIGTERM (#388).
;;;;
;;;;   sbcl --script hyperion/bench/signals/drain.lisp [backend ...]   (default: hunchentoot woo uv)
;;;;
;;;; For each backend: start probe-drain.lisp as a child, wait for its READY line, start a /slow
;;;; request, send the child SIGTERM half a second later, then open new /fast connections at
;;;; 0.2 s, 1 s and 2 s after the signal. Report what each got, whether /slow completed, and
;;;; when the child exited.
;;;;
;;;; THE SIGNAL GOES ONLY TO THE CHILD THIS SCRIPT STARTED. The pid in READY is checked
;;;; against the pid of the process launched here before anything is sent, and /bin/kill is
;;;; given that one number. Nothing else on the machine can be signalled.

(require :asdf)
(require :sb-bsd-sockets)

(defvar *here* (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*)))
(defvar *root* (merge-pathnames "../../../" *here*))

(defun now () (/ (get-internal-real-time) internal-time-units-per-second))

(defun http-get (port path &key (timeout 10))
  "GET PATH on 127.0.0.1:PORT on a new connection. Returns the status line's code, or
:REFUSED, :RESET, :TIMEOUT or :CLOSED-EMPTY."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (handler-case
        (sb-ext:with-timeout timeout
          (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream s :input t :output t
                                                             :element-type :default
                                                             :external-format :latin-1)))
            (format stream "GET ~A HTTP/1.1~C~CHost: x~C~CConnection: close~C~C~C~C"
                    path #\Return #\Newline #\Return #\Newline #\Return #\Newline
                    #\Return #\Newline)
            (force-output stream)
            (let ((line (read-line stream nil nil)))
              (if (and line (> (length line) 12))
                  (values (parse-integer line :start 9 :end 12))
                  :closed-empty))))
      (sb-bsd-sockets:connection-refused-error () :refused)
      (sb-ext:timeout () :timeout)
      (error (e) (if (search "reset" (string-downcase (princ-to-string e))) :reset
                     (intern (string-upcase (substitute #\- #\Space (subseq (princ-to-string e) 0 (min 30 (length (princ-to-string e))))))
                             :keyword)))
      (:no-error (v) (ignore-errors (sb-bsd-sockets:socket-close s)) v))))

(defun measure (backend)
  (let* ((process (uiop:launch-program
                   (list "sbcl" "--dynamic-space-size" "4096" "--script"
                         (namestring (merge-pathnames "probe-drain.lisp" *here*)))
                   :output :stream :error-output :output
                   :environment (append (list (format nil "CL_SOURCE_REGISTRY=~A//:" (namestring *root*))
                                              (format nil "PROBE_BACKEND=~A" backend))
                                        (remove-if (lambda (e) (or (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e)
                                                                   (uiop:string-prefix-p "PROBE_BACKEND=" e)))
                                                   (sb-ext:posix-environ)))))
         (out (uiop:process-info-output process))
         (child (uiop:process-info-pid process))
         pid port)
    (loop for line = (read-line out nil nil)
          while line
          do (cond ((uiop:string-prefix-p "READY " line)
                    (destructuring-bind (_ _b p po) (uiop:split-string line)
                      (declare (ignore _ _b))
                      (setf pid (parse-integer p) port (parse-integer po)))
                    (return))
                   ((uiop:string-prefix-p "PROBE-ERROR" line)
                    (format t "~&~12A SKIP ~A~%" backend line)
                    (return-from measure))))
    (unless (and pid (= pid child))
      (format t "~&~12A REFUSED TO SIGNAL: READY pid ~A is not the launched child ~A~%"
              backend pid child)
      (uiop:terminate-process process :urgent t)
      (return-from measure))
    ;; THREAD-LIFETIME: independent -- the benchmark driver's own client thread.
    (let* ((slow-result nil)
           (slow (sb-thread:make-thread (lambda () (setf slow-result (http-get port "/slow")))
                                        :name "slow request"))
           (t0 (progn (sleep 0.5) (now))))
      (uiop:run-program (list "/bin/kill" "-TERM" (princ-to-string child)))
      (let ((fast (loop for at in '(0.2 1.0 2.0)
                        do (let ((wait (- (+ t0 at) (now)))) (when (plusp wait) (sleep wait)))
                        collect (cons at (http-get port "/fast" :timeout 3)))))
        (sb-thread:join-thread slow :default nil)
        (let* ((rc (uiop:wait-process process))
               (exit (- (now) t0)))
          (format t "~&~12A slow=~A  fast@0.2s=~A  @1s=~A  @2s=~A  exit=~,1Fs rc=~A~%"
                  backend slow-result (cdr (first fast)) (cdr (second fast)) (cdr (third fast))
                  exit rc))))))

(format t "~&BACKEND      what each request got after SIGTERM (slow started 0.5 s before it)~%")
(dolist (b (or (rest sb-ext:*posix-argv*) '("hunchentoot" "woo" "uv")))
  (measure b))
