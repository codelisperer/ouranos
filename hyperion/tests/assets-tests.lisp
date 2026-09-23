;;;; assets-tests.lisp --- the vendored-asset embedding and Bulma theming.
;;;;
;;;; The test that actually earns its place is EMBEDDED-BYTES-MATCH-THE-PIN. Checking
;;;; that an asset is "non-empty" proves nothing -- it passes just as happily with a
;;;; stale fasl, a truncated download, or the wrong version of Bulma. So the suite
;;;; hashes the bytes that are IN THE IMAGE and compares them to the sha256 recorded in
;;;; ASSETS.pin. That is the claim worth making: what the running image will serve is
;;;; the reviewed, pinned content, not merely something.
;;;;
;;;; Its counterpart, `scripts/check-assets.lisp`, checks the files on DISK against the
;;;; same pin. Two different failures: this catches a stale build, that catches a
;;;; tampered or half-updated source tree.
;;;;
;;;; Own package (not hyperion/tests) because hyperion/assets is a separate opt-in
;;;; system and must not make the core test suite depend on it.

(cl:defpackage #:hyperion/assets/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:assets #:hyperion/assets)
                    (#:router #:hyperion/router)))

(in-package #:hyperion/assets/tests)

(def-suite hyperion-assets
  :description "Vendored browser assets: embedding, serving, and Bulma theming.")

(defun run-tests () (run! 'hyperion-assets))

(in-suite hyperion-assets)

;;; --- the embedding ------------------------------------------------------------

(defun %pin-hashes ()
  "Asset name -> sha256, parsed from assets/vendor/ASSETS.pin."
  (let ((table (make-hash-table :test #'equal)))
    (with-open-file (in (asdf:system-relative-pathname
                         "hyperion" "assets/vendor/ASSETS.pin"))
      (loop for line = (read-line in nil)
            while line
            do (let ((words (loop with start = 0
                                  for pos = (position #\Space line :start start)
                                  for word = (string-trim " " (subseq line start pos))
                                  unless (string= word "") collect word
                                  while pos do (setf start (1+ pos)))))
                 ;; "<name> <version> sha256 <hex>"
                 (when (and (= 4 (length words))
                            (string= "sha256" (third words))
                            (not (eql #\# (char line 0))))
                   (setf (gethash (first words) table) (fourth words))))))
    table))

(defun %sha256-hex (octets)
  (string-downcase
   (with-output-to-string (s)
     (loop for b across (ironclad:digest-sequence :sha256 octets)
           do (format s "~2,'0x" b)))))

(test every-declared-asset-is-present
  "The three assets exist, are keyed as expected, and carry bytes."
  (is (= 3 (length (assets:assets))))
  (dolist (key '(:htmx :alpine :bulma))
    (let ((a (assets:asset key)))
      (is (not (null a)) "no asset ~S" key)
      (is (plusp (length (assets:asset-bytes a))) "~S is empty" key))))

(test embedded-bytes-match-the-pin
  "The bytes compiled INTO the image hash to the sha256 recorded in ASSETS.pin.
This is what makes the pin meaningful: it fails on a stale fasl or a swapped file,
where a mere non-emptiness check would pass."
  (let ((pinned (%pin-hashes)))
    (is (= 3 (hash-table-count pinned)) "ASSETS.pin should record three hashes")
    (dolist (a (assets:assets))
      (let* ((name (string-downcase (symbol-name (assets:asset-key a))))
             ;; :alpine is recorded under its npm name.
             (name (if (string= name "alpine") "alpinejs" name))
             (want (gethash name pinned)))
        (is (not (null want)) "ASSETS.pin has no entry for ~a" name)
        (when want
          (is (string= want (%sha256-hex (assets:asset-bytes a)))
              "~a: embedded bytes do not match the pinned sha256" name))))))

(test fingerprint-is-the-head-of-the-hash
  "The URL fingerprint is derived from the real checksum, so the URL changes when --
and only when -- the content does."
  (dolist (a (assets:assets))
    (let ((hex (%sha256-hex (assets:asset-bytes a))))
      (is (string= (assets:asset-fingerprint a) (subseq hex 0 8))
          "~S fingerprint ~a is not the head of ~a"
          (assets:asset-key a) (assets:asset-fingerprint a) hex))))

(test content-types-are-right
  (is (search "javascript" (assets:asset-content-type (assets:asset :htmx))))
  (is (search "javascript" (assets:asset-content-type (assets:asset :alpine))))
  (is (search "text/css" (assets:asset-content-type (assets:asset :bulma)))))

(test unknown-asset-signals
  (signals error (assets:url :tailwind)))

;;; --- serving ------------------------------------------------------------------

(test url-is-content-addressed
  (is (string= "/_hyperion/assets/htmx-449317ad.min.js" (assets:url :htmx)))
  (is (string= "/_hyperion/assets/bulma-67fa26df.min.css" (assets:url :bulma))))

(test prefix-is-honoured-by-both-url-and-mount
  "URL and MOUNT read the same special, so they cannot disagree -- rebinding it moves
the served path and the emitted href together."
  (let ((assets:*prefix* "/static/v"))
    (is (string= "/static/v/htmx-449317ad.min.js" (assets:url :htmx)))
    (let* ((app (router:router (assets:mount)))
           (res (router:dispatch app (list :request-method :get
                                           :path-info (assets:url :htmx)))))
      (is (= 200 (first res))))))

(test mounted-assets-dispatch-and-are-immutable
  (let* ((app (router:router (assets:mount)))
         (res (router:dispatch app (list :request-method :get
                                         :path-info (assets:url :bulma)))))
    (is (= 200 (first res)))
    (is (search "text/css" (getf (second res) :content-type)))
    (is (search "immutable" (getf (second res) :cache-control)))
    (is (= (length (assets:asset-bytes (assets:asset :bulma)))
           (getf (second res) :content-length)))
    ;; The BODY ITSELF is the octet vector -- not a list containing one. This asserted
    ;; `(first (third res))` until #148, which is why the suite stayed green while every
    ;; asset served empty: it was written against the implementation's shape rather than
    ;; the Clack contract, so it locked the defect in instead of catching it.
    (is (equalp (assets:asset-bytes (assets:asset :bulma))
                (third res)))))

(test a-wrong-fingerprint-is-not-served
  "Content addressing has to actually address content: an old fingerprint must 404
rather than quietly serve the current bytes."
  (let* ((app (router:router (assets:mount)))
         (res (router:dispatch app (list :request-method :get
                                         :path-info "/_hyperion/assets/bulma-deadbeef.min.css"))))
    (is (= 404 (first res)))))

;;; --- Bulma theming --------------------------------------------------------------

(test hsl-converts-known-colours
  (flet ((triple (hex)
           (multiple-value-bind (h s l) (assets:hsl hex)
             (list (round h) (round s) (round l)))))
    (is (equal '(0 0 0)     (triple "#000000")))
    (is (equal '(0 0 100)   (triple "#ffffff")))
    (is (equal '(0 100 50)  (triple "#ff0000")))
    (is (equal '(120 100 50) (triple "#00ff00")))
    (is (equal '(240 100 50) (triple "#0000ff")))
    ;; Bulma's own primary. Its docs give 171deg 100% 41%, which is the check that
    ;; matters -- it says our conversion agrees with the numbers Bulma was built from.
    (is (equal '(171 100 41) (triple "#00d1b2")))
    ;; The leading # is optional.
    (is (equal (triple "#00d1b2") (triple "00d1b2")))))

(test hsl-rejects-nonsense
  (signals error (assets:hsl "#fff"))
  (signals error (assets:hsl "#gggggg"))
  (signals error (assets:hsl "")))

(test theme-emits-hsl-triples-for-colours
  (let ((css (assets:theme :primary "#00d1b2")))
    (is (search ":root {" css))
    (is (search "--bulma-primary-h: 171." css))
    (is (search "--bulma-primary-s: 100.0%;" css))
    (is (search "--bulma-primary-l: 41." css))
    ;; The point of the upgrade: no Sass, no build step -- this is just text.
    (is (search "}" css))))

(test theme-passes-non-colour-knobs-through
  (let ((css (assets:theme :family-primary "Inter, sans-serif" :radius-large "8px")))
    (is (search "--bulma-family-primary: Inter, sans-serif;" css))
    (is (search "--bulma-radius-large: 8px;" css))
    (is (not (search "-h:" css)) "a non-colour key must not be expanded to HSL")))

(test theme-handles-several-colours-at-once
  (let ((css (assets:theme :primary "#7048e8" :link "#1d72aa" :danger "#ff0000")))
    (dolist (name '("primary" "link" "danger"))
      (is (search (format nil "--bulma-~a-h:" name) css))
      (is (search (format nil "--bulma-~a-s:" name) css))
      (is (search (format nil "--bulma-~a-l:" name) css)))))

;;; --- over the wire ------------------------------------------------------------
;;;
;;; Everything above proves the bytes are correct IN THE IMAGE. #148 was a bug in
;;; getting them OUT of it: `%respond` returned `(list bytes)` -- a list whose single
;;; element is an octet vector, which is not a Clack body -- so every asset served as
;;; 200 with a correct Content-Length and no content. htmx and Bulma silently failed to
;;; load, and both example apps were dead in the browser while every test here passed.
;;;
;;; The suite could not see it because it never asked the question: the module that
;;; generates the URL is the module that serves it, so a test comparing them agrees
;;; with itself. So this section starts a real server and reads a real socket.
;;;
;;; The client is raw sb-bsd-sockets rather than an HTTP library ON PURPOSE. The claim
;;; is byte-for-byte identity, and a client that decodes the body to a string would
;;; destroy exactly the evidence the test exists to gather -- a latin-1 round-trip was
;;; one of the candidate fixes and it corrupts every byte above 127. HTTP/1.0 with no
;;; keep-alive, so EOF ends the body and a SHORT body (the bug) reads as short rather
;;; than hanging.

(defun %free-port ()
  "An OS-assigned free TCP port, released before it is returned."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun %raw-get (port path)
  "GET PATH from 127.0.0.1:PORT over a raw socket. Returns the whole response as
octets -- headers and body -- with no decoding anywhere."
  (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect sock #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream
                          sock :input t :output t :element-type '(unsigned-byte 8))))
             (write-sequence
              (sb-ext:string-to-octets
               (format nil "GET ~A HTTP/1.0~A~AHost: 127.0.0.1~A~A~A~A"
                       path #\Return #\Newline #\Return #\Newline #\Return #\Newline)
               :external-format :latin-1)
              stream)
             (finish-output stream)
             (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0)))
               (loop for b = (read-byte stream nil nil)
                     while b do (vector-push-extend b out))
               (coerce out '(simple-array (unsigned-byte 8) (*))))))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

(defun %split-response (octets)
  "Split a raw response into (values header-string body-octets) at CRLF CRLF."
  (let ((n (length octets)))
    (loop for i from 0 below (max 0 (- n 3))
          when (and (= 13 (aref octets i)) (= 10 (aref octets (+ i 1)))
                    (= 13 (aref octets (+ i 2))) (= 10 (aref octets (+ i 3))))
            do (return (values (sb-ext:octets-to-string (subseq octets 0 i)
                                                        :external-format :latin-1)
                               (subseq octets (+ i 4))))
          finally (return (values (sb-ext:octets-to-string octets :external-format :latin-1)
                                  #())))))

(defun %await-listening (port &key (tries 100) (pause 0.05))
  "Block until PORT accepts a connection. hyperion/server:START clacks up with
:use-thread t, so it returns BEFORE the socket is listening -- connecting immediately
races it and loses (CONNECTION-REFUSED)."
  (loop repeat tries
        do (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
             (unwind-protect
                  (handler-case (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
                                       (return t))
                    (error () (sleep pause)))
               (ignore-errors (sb-bsd-sockets:socket-close s))))
        finally (error "server on port ~D never started listening" port)))

(defmacro %with-asset-server ((port) &body body)
  "Run BODY against a live server mounting the vendored assets, on a free PORT."
  `(let* ((,port (%free-port))
          (app (router:to-app (router:router (assets:mount))))
          (handler (hyperion/server:start app :port ,port :host "127.0.0.1" :log nil)))
     (unwind-protect (progn (%await-listening ,port) ,@body)
       (ignore-errors (hyperion/server:stop handler)))))

(test every-asset-arrives-byte-for-byte-over-http
  ;; The regression test for #148, and the one that would have caught it. Not "the
  ;; response is non-empty" -- the served bytes must EQUAL the embedded bytes, which is
  ;; the only statement that rules out both truncation and re-encoding.
  (%with-asset-server (port)
    (dolist (a (assets:assets))
      (multiple-value-bind (headers body)
          (%split-response (%raw-get port (assets:url (assets:asset-key a))))
        (is (search "200" headers)
            "~A: expected 200, got header block: ~A" (assets:asset-key a)
            (subseq headers 0 (min 40 (length headers))))
        (is (= (length (assets:asset-bytes a)) (length body))
            "~A: Content-Length promised ~D bytes, ~D arrived."
            (assets:asset-key a) (length (assets:asset-bytes a)) (length body))
        (is (equalp (assets:asset-bytes a) body)
            "~A: served bytes differ from the embedded bytes." (assets:asset-key a))))))

(test bulma-survives-the-wire-unencoded
  ;; Called out separately because it is the case a latin-1 or UTF-8 body would break:
  ;; bulma.min.css is ~678 KB and the largest, so any per-byte re-encoding shows up here
  ;; as a length mismatch even if the small JS files happen to be pure ASCII.
  (%with-asset-server (port)
    (let ((bulma (assets:asset :bulma)))
      (multiple-value-bind (headers body)
          (%split-response (%raw-get port (assets:url :bulma)))
        (declare (ignore headers))
        (is (equalp (assets:asset-bytes bulma) body))))))

(test an-unknown-asset-name-is-not-served
  (%with-asset-server (port)
    (multiple-value-bind (headers body)
        (%split-response (%raw-get port "/_hyperion/assets/nope-00000000.min.js"))
      (declare (ignore body))
      (is (search "404" headers)))))
