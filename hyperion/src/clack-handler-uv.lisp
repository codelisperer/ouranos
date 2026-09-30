;;;; clack-handler-uv.lisp --- a Clack handler for hyperion/server-uv (#373).
;;;;
;;;; (clack:clackup app :server :uv) runs any Clack app on server-uv, once this system is
;;;; loaded: (asdf:load-system "hyperion/clack-handler-uv"). Clack finds a handler by the
;;;; package CLACK.HANDLER.<NAME> and calls its RUN; it stops one started with :USE-THREAD T
;;;; by destroying the thread RUN is blocked in, so RUN stops the server in an
;;;; UNWIND-PROTECT.
;;;;
;;;; This file adapts; server-uv is unchanged in how it is called, and hyperion/server:start
;;;; still calls it directly rather than through Clack (ADR-0020). It does three things:
;;;;
;;;;   THE ENV. server-uv supplies hyperion's Ring keys. A Clack app also reads :SCRIPT-NAME,
;;;;   :REQUEST-URI, :URL-SCHEME, :SERVER-NAME and :SERVER-PORT, and expects :PATH-INFO
;;;;   percent-decoded, as UTF-8, with a replacement character for an invalid sequence.
;;;;   server-uv's :PATH-INFO is the raw target's path, so :REQUEST-URI is built from it.
;;;;
;;;;   RESPONSE HEADERS. A Clack app may give a header the value NIL, meaning "do not send
;;;;   it"; server-uv would send the text NIL. Those pairs are dropped.
;;;;
;;;;   A DELAYED RESPONSE. A Clack app may return a function of a RESPONDER. The app calls the
;;;;   responder with (status headers) and writes through the writer it returns, or with
;;;;   (status headers body) for a whole response. server-uv wants the status and headers
;;;;   returned first, with a function in body position that it later hands its own writer.
;;;;   So the app's function runs in its own thread; the responder passes the head back to
;;;;   the handler, which returns it to server-uv; server-uv's writer is passed to the app's
;;;;   thread; and the stream ends when the app calls its writer with :CLOSE T.
;;;;
;;;; THE HANDLER RUNS SERVER-UV WITH WORKERS. server-uv's default runs handlers on its loop
;;;; thread. A streamed body waiting for the app's thread there would deadlock, because the
;;;; app's writes need the loop. :WORKERS, or :WORKER-NUM as Woo's handler calls it (default
;;;; *DEFAULT-WORKERS*), sets the pool size; a streamed response holds one worker until it ends.
;;;;
;;;; :DEBUG is accepted and ignored: an error in the app is always a 500, as server-uv answers.

(cl:defpackage #:clack.handler.uv
  (:use #:cl)
  (:local-nicknames (#:suv #:hyperion/server-uv)
                    (#:bt #:bordeaux-threads)
                    (#:dyn #:aion/dynamic))
  (:documentation "A Clack handler for hyperion/server-uv: (clack:clackup app :server :uv) (#373).")
  (:export #:run #:stop #:*default-workers*))

(cl:in-package #:clack.handler.uv)

(defvar *default-workers* 16
  "The size of server-uv's worker pool when clackup is given neither :WORKERS nor :WORKER-NUM.

Never zero, and never server-uv's inline dispatch: under it a delayed response deadlocks. Its
body function runs on the loop thread and waits for the app's thread, and the app's writes
are submitted to that same loop. A streamed response holds one worker for as long as it is
open, so an app with many long streams (server-sent events) wants more.")

;;; --- the env ---------------------------------------------------------------

(defun %decode-path (path)
  "PATH with each %XX decoded, read as UTF-8. A sequence that is not UTF-8 becomes U+FFFD, and a
% not followed by two hex digits is kept as written."
  (let ((octets (make-array (length path) :element-type '(unsigned-byte 8)
                                          :fill-pointer 0 :adjustable t))
        (n (length path))
        (i 0))
    (loop while (< i n)
          do (let ((c (char path i)))
               (if (and (char= c #\%) (<= (+ i 3) n)
                        (digit-char-p (char path (+ i 1)) 16)
                        (digit-char-p (char path (+ i 2)) 16))
                   (progn (vector-push-extend (parse-integer path :start (1+ i) :end (+ i 3)
                                                                  :radix 16)
                                              octets)
                          (incf i 3))
                   (progn (loop for o across (sb-ext:string-to-octets (string c)
                                                                      :external-format :utf-8)
                                do (vector-push-extend o octets))
                          (incf i)))))
    (sb-ext:octets-to-string (coerce octets '(simple-array (unsigned-byte 8) (*)))
                             :external-format '(:utf-8 :replacement #\Replacement_Character))))

(defun %host-name (host-header default)
  "The host part of a Host header value, without its port; DEFAULT when there is none."
  (cond ((or (null host-header) (zerop (length host-header))) default)
        ((char= (char host-header 0) #\[)
         (let ((close (position #\] host-header)))
           (if close (subseq host-header 1 close) host-header)))
        (t (let ((colon (position #\: host-header :from-end t)))
             (if colon (subseq host-header 0 colon) host-header)))))

(defun %clack-env (env address port)
  "The Clack env for server-uv's ENV, on a server listening at ADDRESS and PORT."
  (let ((raw-path (getf env :path-info))
        (query (getf env :query-string)))
    (list :request-method (getf env :request-method)
          :script-name ""
          :path-info (%decode-path raw-path)
          :query-string query
          :request-uri (if query (concatenate 'string raw-path "?" query) raw-path)
          :url-scheme "http"
          :server-name (%host-name (gethash "host" (getf env :headers)) address)
          :server-port port
          :server-protocol (getf env :server-protocol)
          :remote-addr (getf env :remote-addr)
          :remote-port (getf env :remote-port)
          :content-type (getf env :content-type)
          :content-length (getf env :content-length)
          :headers (getf env :headers)
          :raw-body (getf env :raw-body)
          :clack.streaming t)))

;;; --- responses -------------------------------------------------------------

(defun %headers (headers)
  "HEADERS without the pairs whose value is NIL."
  (loop for (name value) on headers by #'cddr
        when value collect name and collect value))

(defun %whole (response)
  "A whole Clack response, (status headers body), in server-uv's shape."
  (destructuring-bind (status headers &optional body) response
    (list status (%headers headers) body)))

(defstruct (delayed (:constructor %make-delayed))
  (head-ready (bt:make-semaphore))
  head                                  ; (:whole response), (:stream status headers) or (:error e)
  (writer-ready (bt:make-semaphore))
  uv-writer
  (done (bt:make-semaphore))
  error)

(defun %clack-writer (d)
  "The writer the app's responder returns: (writer data &key start end close)."
  (lambda (data &key (start 0) end close)
    (when (and data (plusp (length data)))
      (funcall (delayed-uv-writer d)
               (if (and (zerop start) (null end)) data (subseq data start end))))
    (when close (bt:signal-semaphore (delayed-done d)))
    (values)))

(defun %responder (d)
  "The function a delayed Clack response is called with."
  (lambda (response)
    (cond ((cddr response)
           (setf (delayed-head d) (list :whole response))
           (bt:signal-semaphore (delayed-head-ready d))
           nil)
          (t
           (setf (delayed-head d) (list :stream (first response) (second response)))
           (bt:signal-semaphore (delayed-head-ready d))
           (bt:wait-on-semaphore (delayed-writer-ready d))
           (%clack-writer d)))))

(defun %delayed (fn)
  "Run FN, a delayed Clack response, and return the response server-uv writes."
  (let ((d (%make-delayed)))
    ;; The app's delayed function continues this request, so it runs with the bindings
    ;; registered for inheritance visible here, such as the request's correlation id (#158).
    (bt:make-thread
     (dyn:inheriting
      (lambda ()
       (handler-case (funcall fn (%responder d))
         (error (e)
           ;; Before the head: the handler signals it, and server-uv answers 500. After it:
           ;; the stream ends without its last chunk, which is how a client learns it failed.
           (setf (delayed-error d) e)
           (if (delayed-head d)
               (bt:signal-semaphore (delayed-done d))
               (progn (setf (delayed-head d) (list :error e))
                      (bt:signal-semaphore (delayed-head-ready d))))))))
     :name "clack-handler-uv delayed response")
    (bt:wait-on-semaphore (delayed-head-ready d))
    (destructuring-bind (kind &rest more) (delayed-head d)
      (ecase kind
        (:error (error (first more)))
        (:whole (%whole (first more)))
        (:stream
         (destructuring-bind (status headers) more
           (list status (%headers headers)
                 (lambda (uv-writer)
                   (setf (delayed-uv-writer d) uv-writer)
                   (bt:signal-semaphore (delayed-writer-ready d))
                   (bt:wait-on-semaphore (delayed-done d))
                   (when (delayed-error d) (error (delayed-error d)))))))))))

(defun %adapt (app address port-box)
  "APP, a Clack app, as a server-uv handler."
  (lambda (env)
    (let ((response (funcall app (%clack-env env address (car port-box)))))
      (if (functionp response)
          (%delayed response)
          (%whole response)))))

;;; --- run and stop ----------------------------------------------------------

(defun run (app &key (address "127.0.0.1") (port 5000) workers worker-num &allow-other-keys)
  "Serve the Clack APP on server-uv at ADDRESS and PORT, and block until this thread is
destroyed, which is how Clack stops a handler started with :USE-THREAD T. The server is
stopped on the way out, so CLACK:STOP leaves no listener behind.

WORKERS, or WORKER-NUM (the key Woo's Clack handler takes, so `:server :woo :worker-num n'
runs unchanged as `:server :uv'), is the size of server-uv's worker pool; see
*DEFAULT-WORKERS*. :DEBUG and the other clackup keys are accepted and ignored."
  (let* ((port-box (list port))
         (server (suv:start (%adapt app address port-box)
                            :host address :port port
                            :workers (or workers worker-num *default-workers*))))
    (setf (car port-box) (suv:server-port server))
    (unwind-protect
         (loop (sleep 60))
      (suv:stop server))))

(defun stop (server)
  "Stop SERVER. Clack calls this only for a handler started without :USE-THREAD, and RUN does
not return in that case, so it is here for the protocol."
  (suv:stop server))
