;;;; htmx.lisp --- the typed HTMX vocabulary, in Coalton.
;;;;
;;;; Coalton owns the checked value; a bad combo can't be spelled (the roadmap's
;;;; litmus test: a real Duration makes "700ms" unspellable-wrong). Pure -- each
;;;; value renders to its attribute string; no IO. The CL/Spinneret side
;;;; (hyperion/html) consumes these renderers at the boundary. First cut of
;;;; roadmap thread 1; the vocabulary grows (OOB detail, SSE/WS, headers, HTMX v4)
;;;; without disturbing call sites.

(cl:in-package #:hyperion/htmx)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- Duration: a checked time, so "700ms" can't be a bare string ---------
  (define-type Duration
    (Millis UFix)
    (Seconds UFix))

  (declare duration->string (Duration -> String))
  (define (duration->string d)
    (match d
      ((Millis n) (<> (the String (into n)) "ms"))
      ((Seconds n) (<> (the String (into n)) "s"))))

  ;;; --- Swap: the hx-swap styles -------------------------------------------
  (define-type Swap
    InnerHTML OuterHTML BeforeBegin AfterBegin BeforeEnd AfterEnd DeleteSwap NoSwap)

  (declare swap->string (Swap -> String))
  (define (swap->string s)
    (match s
      ((InnerHTML) "innerHTML")
      ((OuterHTML) "outerHTML")
      ((BeforeBegin) "beforebegin")
      ((AfterBegin) "afterbegin")
      ((BeforeEnd) "beforeend")
      ((AfterEnd) "afterend")
      ((DeleteSwap) "delete")
      ((NoSwap) "none")))

  ;;; --- Verb: which hx-<verb> attribute carries the URL --------------------
  (define-type Verb Get Post Put Patch Delete)

  (declare verb->attr (Verb -> String))
  (define (verb->attr v)
    (match v
      ((Get) "hx-get")
      ((Post) "hx-post")
      ((Put) "hx-put")
      ((Patch) "hx-patch")
      ((Delete) "hx-delete")))

  ;; The same Verb, rendered as the HTTP method rather than the HTMX attribute. One
  ;; vocabulary, two renderings: the attribute a link sends WITH and the method a
  ;; route answers ON are the same choice, so routing (hyperion/router) reuses this
  ;; type instead of declaring a second five-constructor method enum that could drift
  ;; from it. Also what builds a 405's `Allow:` header.
  (declare verb->method (Verb -> String))
  (define (verb->method v)
    (match v
      ((Get) "GET")
      ((Post) "POST")
      ((Put) "PUT")
      ((Patch) "PATCH")
      ((Delete) "DELETE")))

  ;;; --- Trigger: the hx-trigger expression ---------------------------------
  (define-type Trigger
    (OnEvent String)      ; a DOM event name, e.g. "click"
    (Every Duration)      ; polling: "every 700ms"
    Load
    Revealed)

  (declare trigger->string (Trigger -> String))
  (define (trigger->string tr)
    (match tr
      ((OnEvent e) e)
      ((Every d) (<> "every " (duration->string d)))
      ((Load) "load")
      ((Revealed) "revealed")))

  ;;; --- Target: the hx-target selector -------------------------------------
  (define-type Target
    (CssTarget String)
    ThisElement)

  (declare target->string (Target -> String))
  (define (target->string tg)
    (match tg
      ((CssTarget s) s)
      ((ThisElement) "this")))

  ;;; --- CL-callable scalar helpers -----------------------------------------
  ;;; Coalton `define`d functions are directly callable from CL with CL fixnums;
  ;;; these give the CL/Spinneret side runtime-parametric renders (poll intervals
  ;;; etc.) without constructing Coalton values by hand.
  (declare render-millis (UFix -> String))
  (define (render-millis n) (duration->string (Millis n)))

  (declare render-seconds (UFix -> String))
  (define (render-seconds n) (duration->string (Seconds n)))

  (declare render-every-millis (UFix -> String))
  (define (render-every-millis n) (trigger->string (Every (Millis n))))

  (declare render-every-seconds (UFix -> String))
  (define (render-every-seconds n) (trigger->string (Every (Seconds n)))))
