;;;; translate.lisp --- a general translation capability for Praxeon agents.
;;;;
;;;; A one-shot, stateless LLM translation (no agent, no history): build a provider
;;;; -- optionally a *different*, translation-tuned model than the main agent -- and
;;;; call llm:complete with a "translate only" system prompt. Two uses:
;;;;   - TRANSLATE: a plain function (provider, text, to-locale) -> string, for a
;;;;     client to wrap a turn (Elise renders user<->English around deliberation).
;;;;   - REGISTER: expose translation as a Means so an agent can call it as a tool.
;;;; Provider-neutral (rides praxeon/llm). Model choice: a fast, multilingual model
;;;; keeps cost/latency low; prefer a higher-quality model on sensitive paths.

(cl:defpackage #:praxeon/translate
  (:use #:cl)
  (:local-nicknames (#:llm #:praxeon/llm)
                    (#:cnd #:praxeon/conditions)
                    (#:actor #:praxeon/actor))
  (:documentation
   "One-shot LLM translation for Praxeon. MAKE-TRANSLATOR builds a provider (a
    dedicated translation model via PRAXEON_TRANSLATE_* env, or the app's main
    provider); TRANSLATE renders text between locales; REGISTER exposes it as an
    agent Means. Locale keywords (:es, :ru, ...) map to language names.")
  (:export #:make-translator #:translate #:language-name #:*language-names*
           #:translation-max-tokens #:*minimum-translation-tokens*
           #:register))

(in-package #:praxeon/translate)

(defparameter *language-names*
  '((:en . "English")  (:es . "Spanish")   (:ru . "Russian")   (:fr . "French")
    (:de . "German")   (:it . "Italian")   (:pt . "Portuguese") (:zh . "Chinese")
    (:ja . "Japanese") (:ko . "Korean")    (:ar . "Arabic")     (:hi . "Hindi")
    (:nl . "Dutch")    (:pl . "Polish")    (:tr . "Turkish")    (:uk . "Ukrainian")
    (:sv . "Swedish")  (:no . "Norwegian") (:da . "Danish")     (:fi . "Finnish"))
  "Locale keyword -> English language name, for the translation instruction.
Extend freely; adding a language elsewhere (an i18n file) does not require an entry
here -- an unknown code falls back to its capitalized name.")

(defun language-name (locale)
  "The language name for LOCALE (:es -> \"Spanish\"); the capitalized code otherwise."
  (or (cdr (assoc locale *language-names*))
      (string-capitalize (symbol-name locale))))

(defun make-translator (&key provider model (role :translate))
  "A provider for one-shot translation. Precedence:
  1. an explicit PROVIDER;
  2. an explicit Anthropic MODEL;
  3. the ROLE-scoped provider from the environment -- per-agent model config: the
     translator reads PRAXEON_TRANSLATE_{IMPL,MODEL,API_KEY,AUTH} (role :translate),
     then the backend's own and the shared variables (see llm:make-provider-from-env).
With an explicit MODEL the backend is Anthropic, and the key resolves the same way:
PRAXEON_<ROLE>_API_KEY, then PRAXEON_ANTHROPIC_API_KEY, then PRAXEON_LLM_API_KEY only when
PRAXEON_LLM_IMPL is anthropic (#290).
So translation runs on its own fast, multilingual model/vendor without touching the
main agent; prefer a higher-quality model on sensitive paths."
  (cond
    (provider provider)
    (model (make-instance 'llm:anthropic
                          :model model
                          :api-key (llm:env-setting "anthropic" "API_KEY" :role role)))
    (t (llm:make-provider-from-env :role role))))

(defun %blank-p (s)
  (or (null s)
      (string= "" (string-trim '(#\Space #\Tab #\Newline #\Return) s))))

(defparameter *minimum-translation-tokens* 1024
  "The smallest output limit TRANSLATE gives a translation it sizes itself (#338).")

(defun translation-max-tokens (text)
  "The output limit TRANSLATE uses for TEXT when the caller gives none (#338): twice TEXT's
length in UTF-8 bytes, plus 256, at least *MINIMUM-TRANSLATION-TOKENS* and at most
PRAXEON/LLM:*DEFAULT-MAX-TOKENS*, read when it is called.

A translation is about as long as its source, and TEXT's UTF-8 bytes are already at least its
tokens, since a byte-level tokenizer makes at most one token of each byte, so twice that leaves
room for a target language that takes more
tokens than the source, as scripts other than Latin often do. The ceiling is the limit an app
has set for its model, since a provider can refuse a request above the model's maximum. A text
long enough to need more is cut off and signals TRANSLATION-TRUNCATED rather than returning
part of a translation."
  (max *minimum-translation-tokens*
       (min llm:*default-max-tokens*
            (+ 256 (* 2 (length (sb-ext:string-to-octets text :external-format :utf-8)))))))

(defun %system-prompt (target-lang source-lang)
  (if source-lang
      (format nil "You are a translation engine. Translate the user's message from ~A into ~A. Preserve meaning, tone, register, and any Markdown formatting. Do not answer, interpret, or add anything -- output ONLY the translation." source-lang target-lang)
      (format nil "You are a translation engine. Translate the user's message into ~A. Preserve meaning, tone, register, and any Markdown formatting. Do not answer, interpret, or add anything -- output ONLY the translation."
              target-lang)))

(defun %run (provider text target-lang source-lang max-tokens)
  "The one-shot call: translate TEXT into TARGET-LANG (a language name), optionally from
SOURCE-LANG, with an output limit of MAX-TOKENS, or TRANSLATION-MAX-TOKENS of TEXT when that is
NIL. Returns only the translation.

A translation that stopped at the output limit signals TRANSLATION-TRUNCATED (#338), inside
the restarts RETRY-WITH-MAX-TOKENS, which asks again with a larger limit, and ACCEPT-TRUNCATED,
which returns the cut-off translation with a second value, :TRUNCATED."
  (let ((limit (or max-tokens (translation-max-tokens text)))
        (system (%system-prompt target-lang source-lang)))
    (loop
      (let* ((completion (llm:complete provider (list (llm:msg "user" text))
                                       :system system :max-tokens limit))
             (out (llm:completion-text completion)))
        (if (not (eq (llm:completion-stop-reason completion) :max-tokens))
            (return out)
            (restart-case (error 'cnd:translation-truncated :max-tokens limit :text out)
              (cnd:retry-with-max-tokens (new-limit)
                :report "Translate again with a larger output limit."
                :interactive (lambda ()
                               (format *query-io* "~&New output limit, in tokens: ")
                               (finish-output *query-io*)
                               (list (parse-integer (read-line *query-io*))))
                (check-type new-limit (integer 1))
                (setf limit new-limit))
              (cnd:accept-truncated ()
                :report "Return the cut-off translation, marked as truncated."
                (return (values out :truncated)))))))))

(defun translate (provider text to &key from max-tokens)
  "Translate TEXT into the TO locale on PROVIDER, returning the translated string.
FROM (a locale) names the source language when known -- worth passing, it sharpens
the result. Returns TEXT unchanged when it is blank or FROM eq TO (nothing to do),
or when the translator comes back empty. **Never returns a blank string**: a blank
would render as an empty chat bubble (the handoff silently 'losing' the reply), so
on an empty translation we fall back to the source TEXT -- the user sees the
untranslated reply rather than nothing.

MAX-TOKENS is the output limit. When it is NIL, the default, the limit is sized from TEXT by
TRANSLATION-MAX-TOKENS (#338). A translation that reaches the limit is not returned as though
it were complete: it signals PRAXEON/CONDITIONS:TRANSLATION-TRUNCATED, with the restarts
RETRY-WITH-MAX-TOKENS and ACCEPT-TRUNCATED; after ACCEPT-TRUNCATED this returns the cut-off
translation with a second value, :TRUNCATED."
  (if (or (%blank-p text) (eql from to))
      text
      (multiple-value-bind (out truncated)
          (%run provider text (language-name to) (and from (language-name from)) max-tokens)
        (if (%blank-p out)
            text
            (if truncated (values out truncated) out)))))

;;; --- Optional: translation as an agent-callable Means ----------------------

(defun %schema ()
  "JSON schema for the translate tool: {text, target_language}."
  (let ((props (make-hash-table :test 'equal))
        (text (make-hash-table :test 'equal))
        (lang (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" text) "string"
          (gethash "description" text) "The text to translate.")
    (setf (gethash "type" lang) "string"
          (gethash "description" lang) "Target language name, e.g. \"Spanish\".")
    (setf (gethash "text" props) text
          (gethash "target_language" props) lang)
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "text" "target_language"))
    schema))

(defparameter *description*
  "Translate a piece of text into a target language. Returns only the translation.")

(defun register (agent &key (name "translate") provider model)
  "Register translation as a Means on AGENT so it can invoke it as a tool (mirrors
web-search:register). Uses a dedicated translator provider (see MAKE-TRANSLATOR)."
  (let ((tr (make-translator :provider provider :model model)))
    (actor:register-means agent name *description*
                          (lambda (args)
                            ;; A translation cut off at the limit signals, and the means
                            ;; fails, rather than handing the agent part of a translation.
                            (values (%run tr (gethash "text" args)
                                          (gethash "target_language" args) nil nil)))
                          :schema (%schema))))
