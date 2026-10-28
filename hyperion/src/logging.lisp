;;;; logging.lisp --- request logging + the request-id that correlates a trace.
;;;;
;;;; Clack middleware over the app: every request gets an id, that id is bound into
;;;; aion/log's ambient context, and everything logged while the request runs -- here,
;;;; in mnemosyne, in praxeon, in the app itself -- carries it. That single field is
;;;; what turns scattered lines into a story: `request_id=ab12cd34` selects one
;;;; request's whole path across frameworks.
;;;;
;;;; An id from upstream wins. Edges and proxies (Cloudflare, load balancers, App
;;;; Platform) already mint one per request; adopting theirs means our logs join their
;;;; trace instead of starting a parallel one that cannot be reconciled. We only mint
;;;; an id when nobody upstream did, and echo it back on the response so a user
;;;; reporting a failure can quote something findable.
;;;;
;;;; Levels are chosen so production is readable at :info and diagnosable at :debug --
;;;; one completion line per request at :info, the arrival line at :debug, and errors
;;;; with a backtrace at :error. Nothing here is on a hot loop; the level macros gate
;;;; before any string is built (see aion/log).

(in-package #:hyperion/logging)

(defparameter *request-id-header* "x-request-id"
  "Inbound header consulted for an upstream request id. `X-Request-Id` is the de-facto
convention; set to another name (or NIL to always mint our own) if your edge differs.")

(defparameter *echo-request-id* t
  "When true, the response carries the request id back as `X-Request-Id` -- so a user or
an upstream log can quote the same id we recorded.")

(defparameter *id-bits* 64
  "Entropy in a minted request id. A correlation id, not a secret: it only has to avoid
collisions among requests in flight, so 64 bits is generous.")

(defvar *request-id* nil
  "The current request's id while a request is being handled, for app code that wants to
surface it (an error page, a support reference). NIL outside a request.")


;; Declared inheritable alongside aion/log:*context*, which is bound on the very next line
;; of the middleware below (#158). Both are lost across a thread boundary and both were lost
;; by praxeon/web's turn thread; registering only the context would have carried half the
;; correlation and left a reader wondering why one field crossed and the other did not.
(aion/dynamic:register-inheritable 'hyperion/logging:*request-id*)
(defun new-request-id ()
  "A fresh request id: *ID-BITS* of entropy as lowercase hex, from aion/random.

A request id is NOT a credential -- it correlates log lines and is echoed in a header, and
predicting one grants nothing. It is on the CSPRNG anyway, and the reason is worth stating
because it is not \"defence in depth\": this file previously held a `%id-state' /
`cl:random' pair character-for-character identical to the one that made session ids
guessable (pre-publication issue 95). Leaving the weak template in the same framework, next to the fixed
version, is how it gets copied back the next time somebody needs a random hex string."
  (rnd:random-hex *id-bits*))

(defun request-id (env)
  "The request id for ENV: the upstream header's value if present and non-empty, else a
freshly minted one."
  (let ((upstream (and *request-id-header*
                       (let ((h (getf env :headers)))
                         (and h (gethash (string-downcase *request-id-header*) h))))))
    (if (and upstream (plusp (length upstream)))
        upstream
        (new-request-id))))

;;; --- quiet paths ------------------------------------------------------------
;;; Some routes are machine traffic on a timer: the dev hot-reload poller, a load
;;; balancer's health check, a metrics scrape. One line per request is right for a user
;;; navigating; it is noise for something polling every second forever, and it drowns the
;;; lines you actually wanted.
;;;
;;; Quiet means :TRACE, not :DEBUG. A dev REPL habitually runs at :DEBUG -- that is the
;;; whole point of turning it up -- so demoting to :DEBUG would leave the flood exactly as
;;; it was in the session where it hurts most. :TRACE keeps the events available to anyone
;;; who explicitly asks for everything, and invisible otherwise.
;;;
;;; Errors are NEVER quieted: a failing health check is precisely the thing you need to see.

(defvar *quiet-paths* '()
  "Paths whose successful requests log at :TRACE instead of :INFO. Each entry is either a
path string (exact match) or a predicate of one argument (the path). Errors on these paths
still log normally. See REGISTER-QUIET-PATH.")

(defun register-quiet-path (path-or-predicate)
  "Register PATH-OR-PREDICATE (a path string or a function of the path) as quiet.
Idempotent, so a middleware may register its own endpoints every time it is built.

Middleware registers its OWN routes -- the logger has no business knowing what the dev
loop or a metrics module happens to serve, and that keeps the dependency pointing the
right way."
  (pushnew path-or-predicate *quiet-paths* :test #'equal)
  path-or-predicate)

(defun quiet-path-p (path)
  "True when PATH matches an entry in *QUIET-PATHS*."
  (and path
       (some (lambda (entry)
               (typecase entry
                 (string   (string= entry path))
                 (function (funcall entry path))
                 (t        nil)))
             *quiet-paths*)))

(defun %elapsed-ms (start)
  "Milliseconds since START (an internal-real-time reading), rounded."
  (round (* 1000 (- (get-internal-real-time) start))
         internal-time-units-per-second))

(defun %status-of (response)
  "The status code of a Clack RESPONSE, or NIL if it is not the usual list form (a Clack
app may legally return a function for a delayed/streaming response)."
  (and (consp response) (integerp (first response)) (first response)))

(defun %with-echoed-id (response id)
  "RESPONSE with the request id added as an `X-Request-Id` response header, when RESPONSE
is the ordinary (status headers body) list. Anything else is passed through untouched --
a streaming response owns its own headers."
  (if (and *echo-request-id* (consp response) (consp (cdr response)) (listp (second response)))
      (list* (first response)
             (list* :x-request-id id (second response))
             (cddr response))
      response))

;;; --- the query's parameter names, never its values (#1007) ----------------------------

(defparameter +max-query-keys+ 20
  "The most parameter names the request start line records.")

(defparameter +max-query-key-length+ 40
  "The most characters of one parameter name the request start line records.")

(defun %decode-name (text)
  "TEXT, a query parameter name, with + read as a space and %XX escapes decoded as UTF-8, or NIL
when an escape is malformed or the octets are not UTF-8."
  (let ((octets (make-array (length text) :element-type '(unsigned-byte 8) :fill-pointer 0))
        (i 0) (n (length text)))
    (loop while (< i n)
          do (let ((c (char text i)))
               (cond ((char= c #\%)
                      (let ((hi (and (< (+ i 2) n) (digit-char-p (char text (+ i 1)) 16)))
                            (lo (and (< (+ i 2) n) (digit-char-p (char text (+ i 2)) 16))))
                        (unless (and hi lo) (return-from %decode-name nil))
                        (vector-push (+ (* 16 hi) lo) octets)
                        (incf i 3)))
                     ((> (char-code c) 127) (return-from %decode-name nil))
                     (t (vector-push (if (char= c #\+) 32 (char-code c)) octets)
                        (incf i)))))
    (handler-case (sb-ext:octets-to-string (coerce octets '(simple-array (unsigned-byte 8) (*)))
                                           :external-format '(:utf-8 :replacement nil))
      (error () nil))))

(defun %query-keys (query)
  "The parameter names of QUERY, a raw query string, for the request start line, and how many of
its parts have no = at all: (values NAMES BARE-PARTS).

NAMES are in the order they first appear, each once, at most +MAX-QUERY-KEYS+ of them, each cut
to +MAX-QUERY-KEY-LENGTH+ characters. Never a value: a query string is a payload, and can carry
tokens and personal data (#1007). NIL for no query; :UNPARSED, with no text from it, when a name
has a malformed escape or is not UTF-8.

A part with no =, as in /reset?3f9a..., is counted in BARE-PARTS and never named, because such
a part is usually a token rather than a name (the hub's review of #1017). An empty part, as in
a&&b, is neither."
  (if (and (stringp query) (plusp (length query)))
      (let ((names '()) (bare 0) (full nil))
        (dolist (part (uiop:split-string query :separator "&"))
          (let ((equals (position #\= part)))
            (cond ((zerop (length part)))
                  ((null equals) (incf bare))
                  (full)
                  (t (let ((name (%decode-name (subseq part 0 equals))))
                       (cond ((null name) (return-from %query-keys (values :unparsed bare)))
                             ((zerop (length name)))
                             (t (let ((cut (subseq name 0 (min (length name) +max-query-key-length+))))
                                  (unless (member cut names :test #'string=)
                                    (push cut names)
                                    (when (>= (length names) +max-query-keys+)
                                      (setf full t)))))))))))
        (values (nreverse names) bare))
      (values nil 0)))

(defun wrap (app)
  "Clack middleware: give each request an id, bind it into the logging context so every
framework's events correlate, and log the request's arrival, outcome, and latency.

Errors are logged with a backtrace and then **re-signalled** -- this observes the request,
it does not swallow failures, so Clack's own debug/500 handling still decides what the
client sees."
  (lambda (env)
    (let* ((id (request-id env))
           (start (get-internal-real-time))
           (method (getf env :request-method))
           (path (getf env :path-info))
           (quiet (quiet-path-p path)))
      (log:with-context (:request-id id)
        (let ((*request-id* id))
          ;; The arrival line is redundant for quiet traffic -- the completion line already
          ;; says everything, and doubling the volume is the complaint.
          (unless quiet
            (multiple-value-bind (query-keys bare-parts) (%query-keys (getf env :query-string))
             (log:debug "request start" :method method :path path
                                        ;; The names only, never the values (#1007), and only
                                        ;; a count of the parts with no = (the review of #1017).
                                        :query-keys query-keys
                                        :bare-parts (and (plusp bare-parts) bare-parts)
                                        ;; The client, behind a trusted proxy too (#381).
                                        :remote (proxy:client-address env))))
          (handler-bind
              ((cl:error (lambda (c)
                           ;; Never quieted, whatever the path.
                           (log:exception c "request failed"
                                          :method method :path path
                                          :ms (%elapsed-ms start)))))
            (let* ((response (funcall app env))
                   (status (%status-of response)))
              (if quiet
                  (log:trace "request" :method method :path path
                                       :status status :ms (%elapsed-ms start))
                  (log:info "request" :method method :path path
                                      :status status :ms (%elapsed-ms start)))
              (%with-echoed-id response id))))))))
