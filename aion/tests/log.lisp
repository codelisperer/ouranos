;;;; log.lisp --- tests for aion/log (rendering, context, level gating).

(cl:defpackage #:aion/log/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:log   #:aion/log)
                    (#:types #:aion/log/types)
                    (#:jzon  #:com.inuoe.jzon))
  (:export #:run-tests #:aion-log))
(in-package #:aion/log/tests)

(def-suite aion-log :description "aion/log rendering, context, and level gating.")
(in-suite aion-log)

(test json-render-has-core-fields-and-merges-context
  (let ((log:*layout* :json)
        (log:*context* '(:community "ml")))
    (let* ((line (aion/log::render :info "MY.CAT" "hello" '(:user "u1")))
           (obj  (jzon:parse line)))
      (is (string= "info"   (gethash "level" obj)))
      (is (string= "MY.CAT" (gethash "cat" obj)))
      (is (string= "hello"  (gethash "msg" obj)))
      (is (string= "u1"     (gethash "user" obj)))       ; per-call field
      (is (string= "ml"     (gethash "community" obj)))  ; ambient context
      (is (stringp          (gethash "ts" obj))))))

(test per-call-field-wins-over-context-and-core-keys-protected
  (let ((log:*layout* :json)
        (log:*context* '(:user "ambient" :level "HACK")))   ; :level would clobber a core key
    (let ((obj (jzon:parse (aion/log::render :warn "C" "m" '(:user "call")))))
      (is (string= "call" (gethash "user" obj)))   ; per-call wins over ambient
      (is (string= "warn" (gethash "level" obj))))));  core key not clobbered by a field

(test pretty-render-contains-message-level-and-fields
  (let ((log:*layout* :pretty) (log:*context* '()))
    (let ((line (aion/log::render :warn "C" "slow" '(:ms 5))))
      (is (search "slow" line))
      (is (search "ms=5" line))
      (is (search "WARN" line)))))

(test with-context-merges-and-unwinds
  (let ((log:*context* '(:a 1)))
    (log:with-context (:b 2)
      (is (equal '(:b 2 :a 1) log:*context*)))
    (is (equal '(:a 1) log:*context*))))

(test nil-valued-fields-are-omitted
  (let ((log:*layout* :json) (log:*context* '()))
    (let ((obj (jzon:parse (aion/log::render :info "C" "m" '(:present "yes" :absent nil)))))
      (is (string= "yes" (gethash "present" obj)))
      (is (null (nth-value 1 (gethash "absent" obj)))))))

(test level-gating-suppresses-below-threshold
  (let ((out (make-string-output-stream)))
    (unwind-protect
         (progn
           (log:setup :env :prod :level :warn :stream out)
           (log:info "suppress-me")
           (log:warn "keep-me" :k "v")
           (let ((s (get-output-stream-string out)))
             (is (not (search "suppress-me" s)) "info must be gated below :warn")
             (is (search "keep-me" s))
             (is (search "\"k\":\"v\"" s) "structured field present in JSON")))
      (log:setup :env :dev :level :info))))   ; restore a console appender

;;; --- the typed core (aion/log/types, Coalton) ------------------------------
;;;
;;; These exercise the Coalton layer THROUGH ITS CL BOUNDARY only: strings in, strings and
;;; booleans out, plus Field values that are built by Coalton and handed straight back to
;;; it without ever being inspected here. Nothing below constructs or destructures a Level,
;;; Layout, Field or Event -- a define-type's representation is mode-dependent, so a test
;;; that reached into one would pass in development mode and break under
;;; COALTON_ENV=release (docs/coalton-patterns.md §7).

(test level-order-is-total-and-ranked
  ;; The Ord instance derives from one rank table, so the order cannot disagree with itself.
  (let ((names '("trace" "debug" "info" "warn" "error" "fatal")))
    (is (equal '(0 1 2 3 4 5) (mapcar #'types:level-name-rank names)))
    ;; strictly ascending, pairwise
    (loop for (lo hi) on names while hi
          do (is (< (types:level-name-rank lo) (types:level-name-rank hi))
                 "~A must rank below ~A" lo hi))))

(test level-gating-is-greater-or-equal-over-the-type
  ;; Gating is `>=` on Level, not a hand-maintained keyword table.
  (is (types:level-name-enabled? "warn" "info"))    ; more severe than the threshold
  (is (types:level-name-enabled? "info" "info"))    ; equal is enabled
  (is (not (types:level-name-enabled? "debug" "info")))
  (is (types:level-name-enabled? "fatal" "trace"))
  (is (not (types:level-name-enabled? "trace" "fatal"))))

(test a-misspelled-level-is-rejected-not-silently-ignored
  ;; The bug the type exists to kill: :warm used to be accepted and then never match, so
  ;; the logger went quiet and nothing said why.
  (is (types:valid-level-name? "warn"))
  (is (not (types:valid-level-name? "warm")))
  (is (not (types:valid-level-name? "WARN")))       ; the facade downcases before crossing
  (is (not (types:valid-level-name? "")))
  (is (= -1 (types:level-name-rank "warm")))
  ;; an unknown level is not treated as maximally severe -- it is simply not enabled
  (is (not (types:level-name-enabled? "warm" "trace")))
  (is (not (types:level-name-enabled? "info" "warm"))))

(test level-bang-signals-on-a-level-that-does-not-exist
  ;; The payoff at the configuration seam, where a caller can act on it.
  (signals cl:error (log:level! :warm))
  (signals cl:error (log:setup :env :dev :level :inof))
  ;; and the real ones still work
  (unwind-protect (is (eq :warn (log:level! :warn)))
    (log:setup :env :dev :level :info)))

(test layout-names-are-validated
  (is (types:valid-layout-name? "pretty"))
  (is (types:valid-layout-name? "json"))
  (is (not (types:valid-layout-name? "yaml"))))

(test typed-render-pretty-shape
  ;; ts LEVEL(padded to 5) [cat] message k=v ...
  (let ((line (types:render-event-line
               "pretty" "info" "MY.CAT" "hello" "2026-01-01T00:00:00Z"
               (list (types:mk-field-string "user" "u1")
                     (types:mk-field-raw "n" "42")))))
    (is (string= "2026-01-01T00:00:00Z INFO  [MY.CAT] hello user=u1 n=42" line))))

(test typed-render-json-shape-and-escaping
  (let* ((line (types:render-event-line
                "json" "warn" "C" "he said \"hi\"" "2026-01-01T00:00:00Z"
                (list (types:mk-field-string "path" "a\\b")
                      (types:mk-field-raw "n" "42")
                      (types:mk-field-raw "ok" "true"))))
         (obj (jzon:parse line)))
    ;; parses at all -- which is the escaping assertion that matters
    (is (string= "warn" (gethash "level" obj)))
    (is (string= "he said \"hi\"" (gethash "msg" obj)))
    (is (string= "a\\b" (gethash "path" obj)))
    ;; raw values are JSON literals, not strings
    (is (eql 42 (gethash "n" obj)))
    (is (eq t (gethash "ok" obj)))
    (is (search "\"n\":42" line) "a number must not be quoted")))

(test typed-render-keeps-the-first-field-of-a-repeated-key
  (let ((obj (jzon:parse (types:render-event-line
                          "json" "info" "C" "m" "TS"
                          (list (types:mk-field-string "k" "first")
                                (types:mk-field-string "k" "second"))))))
    (is (string= "first" (gethash "k" obj)))))

(test typed-render-protects-the-core-keys
  ;; A field called level/ts/cat/msg cannot displace the real one.
  (let ((obj (jzon:parse (types:render-event-line
                          "json" "info" "REAL.CAT" "real-msg" "REAL-TS"
                          (list (types:mk-field-string "level" "HACK")
                                (types:mk-field-string "ts" "HACK")
                                (types:mk-field-string "cat" "HACK")
                                (types:mk-field-string "msg" "HACK"))))))
    (is (string= "info" (gethash "level" obj)))
    (is (string= "REAL-TS" (gethash "ts" obj)))
    (is (string= "REAL.CAT" (gethash "cat" obj)))
    (is (string= "real-msg" (gethash "msg" obj)))))

(test typed-render-falls-back-rather-than-refusing-to-log
  ;; On the emission path, refusing to render because a name was misspelled would lose the
  ;; very event someone is trying to read. Configuration-time validation is where a typo is
  ;; caught (see LEVEL-BANG-SIGNALS...); here we degrade.
  (let ((line (types:render-event-line "yaml" "warm" "C" "still-logged" "TS" '())))
    (is (search "still-logged" line))
    (is (search "INFO" line) "an unknown level renders as info")
    (is (not (search "{" line)) "an unknown layout renders pretty")))

(test the-facade-classifies-cl-values-for-json
  ;; The decode point: CL's open type universe -> JSON's four scalar shapes, once per field.
  (let ((log:*layout* :json) (log:*context* '()))
    (let ((obj (jzon:parse (aion/log::render :info "C" "m"
                                             '(:s "str" :i 7 :f 1.5 :true t :sym :a-keyword)))))
      (is (string= "str" (gethash "s" obj)))
      (is (eql 7 (gethash "i" obj)))
      (is (eq t (gethash "true" obj)))
      (is (string= "a-keyword" (gethash "sym" obj)))
      ;; a float must round-trip as a number, not a quoted string
      (is (numberp (gethash "f" obj))))))

(test render-checks-the-field-list-before-it-enters-coalton
  ;; #110: Coalton checks that the fields argument is a list, not what is in it. %FIELDS only
  ;; ever builds Fields, so it is replaced here with one that returns a non-Field second.
  (let ((real (fdefinition 'aion/log::%fields)))
    (unwind-protect
         (progn
           (setf (fdefinition 'aion/log::%fields)
                 (lambda (extra)
                   (declare (ignore extra))
                   (list (aion/log/types:mk-field-string "k" "v") :not-a-field)))
           (let ((e (handler-case (progn (aion/log::render :info "C" "m" '()) nil)
                      (aion/boundary:boundary-type-error (e) e))))
             (is (typep e 'aion/boundary:boundary-type-error) "render did not signal")
             (is (eql 1 (and e (aion/boundary:boundary-type-error-index e))))
             (is (eq 'aion/log/types:render-event-line
                     (and e (aion/boundary:boundary-type-error-function e))))))
      (setf (fdefinition 'aion/log::%fields) real))))

(defun run-tests ()
  "Run the aion/log suite; return T on success (for `asdf:test-system`).
Named RUN-TESTS, not RUN -- FiveAM already exports RUN."
  (run! 'aion-log))
