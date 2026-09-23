;;;; chat-rbt.lisp --- ChatRBT: conversational Requirements-Based Testing (placeholder)
;;;;
;;;; ChatRBT is Elenchon's motivating example app, but it lives here in Praxeon
;;;; (alongside Elise) so the dependency flows one way: this example depends on
;;;; both praxeon and elenchon; neither framework depends on the example, and
;;;; elenchon's repo never has to pull praxeon/hyperion (no circular dependency).
;;;;
;;;; What it will do: a user states functional requirements in plain English; a
;;;; Praxeon actor (a) converses to disambiguate them, (b) reframes each as a
;;;; Cause-Effect Graph via Elenchon, and (c) runs the CEG to generate the minimal
;;;; set of functional test cases. A background "capture" agent collates the CEGs
;;;; and cases into a project-level view of artifacts as they are produced -- so the
;;;; chat is a *popup* over that artifact surface, not the whole app. (See README.)
;;;;
;;;; The capture agent is the same shape as Elise's "Scribe": a second agent,
;;;; coordinated with the conversational one (praxeon/actor:register-agent-as-means
;;;; or praxeon/workflow), that produces structured artifacts alongside the chat.
;;;;
;;;; Status: PLACEHOLDER. Elenchon's CEG core and solver do not exist yet (v0.0.0);
;;;; this app is the forcing function that will drive them. It loads and reports
;;;; its version; START signals that the pipeline is still pending.

(cl:defpackage #:praxeon/chat-rbt
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor))  ; the conversational + capture agents
  (:documentation
   "ChatRBT: turn English functional requirements into Cause-Effect Graphs and
    generate functional test cases -- Elenchon's motivating example (placeholder,
    hosted in Praxeon to keep the dependency acyclic).")
  (:export #:version #:start))

(cl:in-package #:praxeon/chat-rbt)

(defparameter +version+ "0.0.0"
  "ChatRBT version. Placeholder -- awaits Elenchon's CEG core + solver.")

(defun version ()
  "Return the ChatRBT version string."
  +version+)

(defun start (&rest args)
  "Placeholder entry point. ChatRBT's pipeline (English requirement -> CEG -> test
cases) awaits Elenchon's CEG core and solver; see examples/chat-rbt/README.md for
the design and the open questions."
  (declare (ignore args))
  ;; Resolve elenchon:version at runtime (not read time) so the file compiles in
  ;; any image, even one that hasn't loaded :elenchon yet (e.g. Alive's LSP).
  (error "ChatRBT is a placeholder: Elenchon's CEG core/solver are not implemented yet (Elenchon v~A). See examples/chat-rbt/README.md."
         (uiop:symbol-call '#:elenchon '#:version)))
