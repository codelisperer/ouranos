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
                    (#:actor #:praxeon/actor))
  (:documentation
   "One-shot LLM translation for Praxeon. MAKE-TRANSLATOR builds a provider (a
    dedicated translation model via PRAXEON_TRANSLATE_* env, or the app's main
    provider); TRANSLATE renders text between locales; REGISTER exposes it as an
    agent Means. Locale keywords (:es, :ru, ...) map to language names.")
  (:export #:make-translator #:translate #:language-name #:*language-names*
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
     falling back to the shared PRAXEON_LLM_* (see llm:make-provider-from-env).
So translation runs on its own fast, multilingual model/vendor without touching the
main agent; prefer a higher-quality model on sensitive paths."
  (cond
    (provider provider)
    (model (make-instance 'llm:anthropic
                          :model model
                          :api-key (or (uiop:getenv "PRAXEON_TRANSLATE_API_KEY")
                                       (uiop:getenv "PRAXEON_LLM_API_KEY"))
                          :auth :api-key))
    (t (llm:make-provider-from-env :role role))))

(defun %blank-p (s)
  (or (null s)
      (string= "" (string-trim '(#\Space #\Tab #\Newline #\Return) s))))

(defun %run (provider text target-lang source-lang max-tokens)
  "The one-shot call: translate TEXT into TARGET-LANG (a language name), optionally
from SOURCE-LANG. Returns only the translation."
  (let ((system
          (if source-lang
              (format nil "You are a translation engine. Translate the user's message from ~A into ~A. Preserve meaning, tone, register, and any Markdown formatting. Do not answer, interpret, or add anything -- output ONLY the translation." source-lang target-lang)
              (format nil "You are a translation engine. Translate the user's message into ~A. Preserve meaning, tone, register, and any Markdown formatting. Do not answer, interpret, or add anything -- output ONLY the translation."
                      target-lang))))
    (llm:completion-text
     (llm:complete provider (list (llm:msg "user" text))
                   :system system :max-tokens max-tokens))))

(defun translate (provider text to &key from (max-tokens 2048))
  "Translate TEXT into the TO locale on PROVIDER, returning the translated string.
FROM (a locale) names the source language when known -- worth passing, it sharpens
the result. Returns TEXT unchanged when it is blank or FROM eq TO (nothing to do),
or when the translator comes back empty. **Never returns a blank string**: a blank
would render as an empty chat bubble (the handoff silently 'losing' the reply), so
on an empty translation we fall back to the source TEXT -- the user sees the
untranslated reply rather than nothing."
  (if (or (%blank-p text) (eql from to))
      text
      (let ((out (%run provider text (language-name to)
                       (and from (language-name from)) max-tokens)))
        (if (%blank-p out) text out))))

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
                            (%run tr (gethash "text" args)
                                  (gethash "target_language" args) nil 2048))
                          :schema (%schema))))
