;;;; server.lisp --- a small HTTP app for dokimasia's browser tests (#1028).
;;;;
;;;; It listens on 127.0.0.1 at a port the system chooses and answers each connection on its own
;;;; thread, closing the connection after one response. Its pages are made for the checks: a
;;;; sign-up and sign-in flow with a store the tests can read directly, a page that logs a console
;;;; error, one that logs a known message, one that requests the same URL in a loop, one whose
;;;; request is answered with 500, a scrolling pane, and a clock to mask in screenshots. Started
;;;; with :FAVICON NIL it has no /favicon.ico, for the pages that link no icon or a missing one.

(in-package #:dokimasia/tests)

(defstruct (app (:constructor %make-app))
  listener thread port
  (favicon t)
  (lock (sb-thread:make-mutex :name "dokimasia test app"))
  (users (make-hash-table :test 'equal))
  (sessions (make-hash-table :test 'equal)))

(defun app-base-url (app) (format nil "http://127.0.0.1:~D" (app-port app)))

(defun app-user (app email)
  "The stored user EMAIL as a plist (:email :password :plan), or NIL."
  (sb-thread:with-mutex ((app-lock app)) (gethash email (app-users app))))

(defun %store-user (app email password plan)
  (sb-thread:with-mutex ((app-lock app))
    (setf (gethash email (app-users app)) (list :email email :password password :plan plan))))

(defun %new-session (app email)
  (let ((id (format nil "~36R" (random (expt 36 12) (make-random-state t)))))
    (sb-thread:with-mutex ((app-lock app)) (setf (gethash id (app-sessions app)) email))
    id))

(defun %session-email (app cookie)
  (let* ((p (and cookie (search "session=" cookie)))
         (id (and p (subseq cookie (+ p 8) (or (position #\; cookie :start p) (length cookie))))))
    (and id (sb-thread:with-mutex ((app-lock app)) (gethash id (app-sessions app))))))

;;; --- HTTP ----------------------------------------------------------------------------------

(defun %read-line-crlf (stream)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil)
          do (cond ((null b) (return (and (plusp (length bytes))
                                          (sb-ext:octets-to-string bytes :external-format :utf-8))))
                   ((= b 10) (return (string-right-trim '(#\Return)
                                                        (sb-ext:octets-to-string bytes :external-format :utf-8))))
                   (t (vector-push-extend b bytes))))))

(defun %url-decode (text)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (i 0))
    (loop while (< i (length text))
          do (let ((c (char text i)))
               (cond ((char= c #\+) (vector-push-extend 32 bytes) (incf i))
                     ((and (char= c #\%) (<= (+ i 3) (length text)))
                      (vector-push-extend (parse-integer text :start (1+ i) :end (+ i 3) :radix 16) bytes)
                      (incf i 3))
                     (t (loop for b across (sb-ext:string-to-octets (string c) :external-format :utf-8)
                              do (vector-push-extend b bytes))
                        (incf i)))))
    (sb-ext:octets-to-string bytes :external-format :utf-8)))

(defun %form-fields (text)
  (loop for pair in (uiop:split-string text :separator "&")
        for eq = (position #\= pair)
        when eq collect (cons (%url-decode (subseq pair 0 eq)) (%url-decode (subseq pair (1+ eq))))))

(defun %field (fields name) (or (cdr (assoc name fields :test #'string=)) ""))

(defun %escape (text)
  (with-output-to-string (s)
    (loop for c across text
          do (case c (#\< (write-string "&lt;" s)) (#\> (write-string "&gt;" s))
                   (#\& (write-string "&amp;" s)) (#\" (write-string "&quot;" s))
                   (t (write-char c s))))))

(defun %respond (stream status &key (type "text/html; charset=utf-8") (body "") headers)
  (let ((octets (sb-ext:string-to-octets body :external-format :utf-8)))
    (write-sequence
     (sb-ext:string-to-octets
      (format nil "HTTP/1.1 ~D X~C~CContent-Type: ~A~C~CContent-Length: ~D~C~CConnection: close~C~CCache-Control: no-store~C~C~{~A~C~C~}~C~C"
              status #\Return #\Newline type #\Return #\Newline (length octets) #\Return #\Newline
              #\Return #\Newline #\Return #\Newline
              (loop for h in headers append (list h #\Return #\Newline))
              #\Return #\Newline)
      :external-format :latin-1)
     stream)
    (write-sequence octets stream)
    (force-output stream)))

(defun %page (title body &optional (script ""))
  (format nil "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>~A</title><style>body{font-family:sans-serif;margin:2em} @media (prefers-color-scheme: dark){body{background:#111;color:#eee}}</style></head><body>~A<script>~A</script></body></html>"
          title body script))

(defun %icon-page (href)
  "A page that links the icon HREF itself."
  (format nil "<!doctype html><html><head><meta charset=\"utf-8\"><title>Icon</title><link rel=\"icon\" href=\"~A\"></head><body><h1 id=\"title\">Icon</h1></body></html>"
          href))

(defun %a11y-page (title body &optional (style ""))
  "A page for the :audit tests: it has a language, a title and the viewport line, so the only
violations axe-core finds are the ones BODY and STYLE put there."
  (format nil "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>~A</title><style>~A</style></head><body>~A</body></html>"
          title style body))

(defparameter +a11y-ok+ "<main><h1 id=\"title\">Accessible</h1><p>Plain text in the main landmark.</p></main>")

(defun %redirect (stream location &rest headers)
  (%respond stream 303 :headers (cons (format nil "Location: ~A" location) headers)))

;;; --- the app's pages -------------------------------------------------------------------------

(defparameter +signup-form+
  "<h1>Sign up</h1><form id=\"signup\" method=\"post\" action=\"/signup\"><input id=\"email\" name=\"email\"><input id=\"password\" name=\"password\" type=\"password\"><select id=\"plan\" name=\"plan\"><option value=\"free\">Free</option><option value=\"pro\">Pro</option></select><button id=\"submit\" type=\"submit\">Sign up</button></form>")

(defun %login-form (&optional error)
  (format nil "<h1>Sign in</h1>~@[<p id=\"error\">~A</p>~]<form id=\"login\" method=\"post\" action=\"/login\"><input id=\"email\" name=\"email\"><input id=\"password\" name=\"password\" type=\"password\"><button id=\"submit\" type=\"submit\">Sign in</button></form>"
          error))

(defun %route (app stream method path cookie body)
  (let ((email (%session-email app cookie)))
    (cond
      ((and (string= path "/favicon.ico") (app-favicon app)) (%respond stream 204))
      ((string= path "/no-icon")
       (%respond stream 200 :body (%page "No icon" "<h1 id=\"title\">No icon</h1>")))
      ((string= path "/own-icon")
       (%respond stream 200 :body (%icon-page "/missing-icon.png")))
      ((string= path "/own-favicon")
       (%respond stream 200 :body (%icon-page "/favicon.ico")))
      ((and (string= method "GET") (string= path "/signup"))
       (%respond stream 200 :body (%page "Sign up" +signup-form+)))
      ((and (string= method "POST") (string= path "/signup"))
       (let ((f (%form-fields body)))
         (%store-user app (%field f "email") (%field f "password") (%field f "plan"))
         (%redirect stream "/home"
                    (format nil "Set-Cookie: session=~A; Path=/; HttpOnly"
                            (%new-session app (%field f "email"))))))
      ((and (string= method "GET") (string= path "/login"))
       (%respond stream 200 :body (%page "Sign in" (%login-form))))
      ((and (string= method "POST") (string= path "/login"))
       (let* ((f (%form-fields body))
              (user (app-user app (%field f "email"))))
         (if (and user (string= (getf user :password) (%field f "password")))
             (%redirect stream "/home"
                        (format nil "Set-Cookie: session=~A; Path=/; HttpOnly"
                                (%new-session app (%field f "email"))))
             (%respond stream 200 :body (%page "Sign in" (%login-form "Wrong email or password"))))))
      ((string= path "/home")
       (if email
           (%respond stream 200
                     :body (%page "Home"
                                  (format nil "<h1 id=\"welcome\">Welcome, ~A</h1><p>It is <span id=\"clock\">~D</span>.</p><p class=\"stamp\">Generated at ~D</p>"
                                          (%escape email) (get-universal-time) (get-universal-time))))
           (%redirect stream "/login")))
      ((uiop:string-prefix-p "/api/user/" path)
       (let ((user (app-user app (%url-decode (subseq path 10)))))
         (if user
             (%respond stream 200 :type "application/json"
                                  :body (format nil "{\"email\":~A,\"plan\":~A}"
                                                (jzon:stringify (getf user :email))
                                                (jzon:stringify (getf user :plan))))
             (%respond stream 404 :type "application/json" :body "{}"))))
      ((string= path "/console-error")
       (%respond stream 200 :body (%page "Console" "<h1 id=\"title\">Console</h1>" "console.error('boom from the page');")))
      ((string= path "/known-console")
       (%respond stream 200 :body (%page "Known" "<h1 id=\"title\">Known</h1>" "console.error('known noise from a widget');")))
      ((string= path "/loop")
       (%respond stream 200 :body (%page "Loop" "<h1 id=\"title\">Loop</h1>"
                                         "(async () => { for (let i = 0; i < 30; i++) await fetch('/api/ping'); document.title = 'Loop done'; })();")))
      ((string= path "/api/ping") (%respond stream 200 :type "application/json" :body "{\"ok\":true}"))
      ((string= path "/server-error")
       (%respond stream 200 :body (%page "Error" "<h1 id=\"title\">Error</h1>"
                                         "fetch('/api/fail').catch(() => {});")))
      ((string= path "/api/fail") (%respond stream 500 :type "application/json" :body "{\"error\":\"down\"}"))
      ((string= path "/pane")
       (%respond stream 200
                 :body (%page "Pane"
                              (format nil "<div id=\"list\" style=\"height:200px;overflow:auto\">~{<p>item ~D</p>~}</div><button id=\"more\">More</button><button id=\"top\">Top</button>"
                                      (loop for i from 1 to 60 collect i))
                              "document.getElementById('more').onclick = () => { const l = document.getElementById('list'); for (let i = 0; i < 5; i++) { const p = document.createElement('p'); p.textContent = 'more'; l.appendChild(p); } }; document.getElementById('top').onclick = () => { document.getElementById('list').scrollTop = 0; };")))
      ;; The :audit tests. /a11y-ok has no violation. /a11y-moderate has only moderate ones (no
      ;; landmark, no h1). /a11y-image has an image without alt text, which axe-core rates
      ;; critical. /a11y-dark has enough contrast in the light scheme and too little in the dark.
      ((string= path "/a11y-ok") (%respond stream 200 :body (%a11y-page "OK" +a11y-ok+)))
      ((string= path "/a11y-moderate")
       (%respond stream 200 :body (%a11y-page "Moderate" "<p id=\"title\">Text outside any landmark.</p>")))
      ((string= path "/a11y-image")
       (%respond stream 200
                 :body (%a11y-page "Image" "<main><h1 id=\"title\">Image</h1><img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACwAAAAAAQABAAACAkQBADs=\" width=\"20\" height=\"20\"></main>")))
      ((string= path "/a11y-dark")
       (%respond stream 200
                 :body (%a11y-page "Dark" +a11y-ok+
                                   "body{background:#fff;color:#000} @media (prefers-color-scheme: dark){body{background:#222;color:#333}}")))
      (t (%respond stream 404 :body (%page "Not found" "<h1>Not found</h1>"))))))

(defun %serve-connection (app socket)
  (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                          :element-type '(unsigned-byte 8)
                                                          :buffering :full)))
    (let* ((request-line (%read-line-crlf stream))
           (parts (and request-line (uiop:split-string request-line :separator " ")))
           (headers (loop for line = (%read-line-crlf stream)
                          while (and line (plusp (length line)))
                          collect (let ((c (position #\: line)))
                                    (cons (string-downcase (subseq line 0 c))
                                          (string-trim " " (subseq line (1+ c)))))))
           (length (parse-integer (or (cdr (assoc "content-length" headers :test #'string=)) "0")
                                  :junk-allowed t))
           (body (if (and length (plusp length))
                     (let ((buf (make-array length :element-type '(unsigned-byte 8))))
                       (read-sequence buf stream)
                       (sb-ext:octets-to-string buf :external-format :utf-8))
                     "")))
      (when (>= (length parts) 2)
        (%route app stream (first parts) (second parts)
                (cdr (assoc "cookie" headers :test #'string=)) body)))))

(defun start-app (&key users (favicon t))
  "Start the test app with USERS, plists (:email :password :plan), already signed up. With FAVICON
NIL, /favicon.ico is answered with 404."
  (let* ((listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (app (%make-app :listener listener :favicon favicon)))
    (dolist (u users) (%store-user app (getf u :email) (getf u :password) (getf u :plan)))
    (setf (sb-bsd-sockets:sockopt-reuse-address listener) t)
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 32)
    (setf (app-port app) (nth-value 1 (sb-bsd-sockets:socket-name listener)))
    (setf (app-thread app)
          (sb-thread:make-thread
           (lambda ()
             (aion/dynamic:unblock-interrupts)
             (loop
               (let ((client (handler-case (sb-bsd-sockets:socket-accept listener)
                               (error () (return)))))
                 (when client
                   (sb-thread:make-thread
                    (lambda ()
                      (aion/dynamic:unblock-interrupts)
                      (unwind-protect (ignore-errors (%serve-connection app client))
                        (ignore-errors (sb-bsd-sockets:socket-close client))))
                    :name "dokimasia test app connection")))))
           :name "dokimasia test app"))
    app))

(defun stop-app (app)
  "Stop accepting connections. Closing the listener does not always wake a thread blocked in
accept on macOS, so the accepting thread is also terminated when it is still alive."
  (ignore-errors (sb-bsd-sockets:socket-close (app-listener app)))
  (let ((thread (app-thread app)))
    (unless (sb-thread:join-thread thread :timeout 1 :default nil)
      (when (sb-thread:thread-alive-p thread)
        (ignore-errors (sb-thread:terminate-thread thread))
        (sb-thread:join-thread thread :timeout 5 :default nil)))))
