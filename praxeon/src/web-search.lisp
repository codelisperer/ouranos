;;;; web-search.lisp --- a web-search Means (Tavily-backed) for Praxeon agents.
;;;;
;;;; In praxeological terms this is a *Means* an Actor applies toward the *End* of
;;;; understanding the user: when a term, name, or reference in the input doesn't
;;;; parse, the model can call "web-search" to fetch context and fold it back in.
;;;; It exercises the whole deliberate -> act -> tool-result -> deliberate loop on
;;;; something genuinely useful.
;;;;
;;;; The *effect* (the HTTP call) lives here in the CL shell, as it must -- it does
;;;; IO. The means is provider-neutral at the Actor level (it's just a registered
;;;; means with a JSON schema); Tavily is the current backend, swappable later
;;;; without touching the loop. The result is kept compact on purpose: the scarce
;;;; resource an agent economizes is the context/token budget.

(cl:defpackage #:praxeon/web-search
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:tavily-search #:register #:*endpoint* #:*max-results*))

(cl:in-package #:praxeon/web-search)

(defparameter *endpoint* "https://api.tavily.com/search")
(defparameter *max-results* 3
  "How many source results to include in the compact summary.")

(defun %api-key ()
  (or (uiop:getenv "TAVILY_API_KEY")
      (error "TAVILY_API_KEY is not set (put it in .env or the environment).")))

(defun %truncate (str n)
  (let ((str (or str "")))
    (if (> (length str) n)
        (concatenate 'string (subseq str 0 n) "…")
        str)))

(defun %format-results (parsed &key (max *max-results*))
  "Render Tavily's parsed JSON (a hash-table with \"answer\" and \"results\") as a
compact plain-text summary suitable to feed back as tool context."
  (let ((answer (gethash "answer" parsed))
        (results (gethash "results" parsed)))
    (with-output-to-string (s)
      (when (and (stringp answer) (plusp (length answer)))
        (format s "~A~2%" answer))
      (when (and results (plusp (length results)))
        (write-line "Sources:" s)
        (loop for r across results
              for i from 1 to max
              do (format s "~D. ~A — ~A~%   ~A~%"
                         i (gethash "title" r "") (gethash "url" r "")
                         (%truncate (gethash "content" r "") 240)))))))

(defun tavily-search (query &key (max-results *max-results*))
  "Search the web via Tavily for QUERY; return a compact text summary (a
synthesized answer plus a few sources). Signals on HTTP/parse failure so the
ACT restart protocol (retry / substitute / abandon) applies."
  ;; Build the request JSON by hand to keep booleans unambiguous; jzon:stringify
  ;; handles escaping the string values (api key, query).
  (let* ((body (format nil "{\"api_key\":~A,\"query\":~A,\"max_results\":~D,\"include_answer\":true,\"search_depth\":\"basic\"}"
                       (jzon:stringify (%api-key)) (jzon:stringify query) max-results))
         ;; Through the shared client (pre-publication issue 202) rather than raw dexador: a non-2xx now
         ;; carries the provider's own explanation instead of an opaque failure.
         (resp (http:response-body
                (http:send-request
                 (http:make-request :method :post :url *endpoint*
                                    :headers '(("content-type" . "application/json"))
                                    :content body)
                 (list (http:ensure-2xx "tavily"))))))
    (%format-results (jzon:parse resp) :max max-results)))

(defun %schema ()
  "The JSON input-schema for the means: a single required string, QUERY."
  (let ((q (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" q) "string"
          (gethash "description" q)
          "What to look up on the web -- e.g. an unfamiliar term, name, or reference.")
    (setf (gethash "query" props) q)
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "query"))
    schema))

(defparameter *description*
  "Search the web for current information, or to clarify an unfamiliar term, name,
or reference in the user's message. Returns a short summary with source links. Use
it when understanding the user depends on facts you are unsure of.")

(defun register (agent &key (name "web-search"))
  "Register the web-search Means on AGENT under NAME. The effect reads the \"query\"
argument from the tool call and runs TAVILY-SEARCH. Returns NAME."
  (actor:register-means
   agent name *description*
   (lambda (args) (tavily-search (gethash "query" args)))
   :schema (%schema)))
