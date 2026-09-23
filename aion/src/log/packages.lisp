;;;; packages.lisp --- aion/log: a neutral logging facade.
;;;;
;;;; A thin, backend-neutral logging surface for the Ouranos frameworks and the apps that
;;;; ride them. The *engine* is log4cl (adopted, not rebuilt): level gating that compiles
;;;; away when disabled, a per-package category hierarchy, runtime level control, and SLIME
;;;; integration. The facade owns the *shape*: leveled calls + structured context, rendered
;;;; pretty for dev (human + SLIME) and as one-line JSON for staging/prod (App Platform
;;;; captures stdout). Effects live here in the CL shell -- Coalton cores never log; they
;;;; return values and the shell logs. Swap the backend by reimplementing log.lisp; callers
;;;; (aion/log:info ...) don't change.

(cl:defpackage #:aion/log/types
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:lst #:coalton-library/list))
  (:documentation
   "The typed core of aion/log: Level (ordered), Layout, Field and Event, plus a RENDER
    that is exhaustive over Layout by construction. This is where the logger's untyped
    keyword vocabulary becomes typed values, decoded once at the boundary -- see
    ../../docs/coalton-story.md. Pure: no IO, no log4cl, no clock. The CL facade next door
    calls only the monomorphic wrappers, which traffic in Coalton's promised
    representations (String/Boolean/Integer/List) and never expose an ADT's shape.")
  (:export #:Level #:LvTrace #:LvDebug #:LvInfo #:LvWarn #:LvError #:LvFatal
           #:level-rank #:level->string #:level->padded #:parse-level #:level-enabled?
           #:Layout #:Pretty #:Json #:layout->string #:parse-layout
           #:FieldValue #:FStr #:FRaw #:field-value->string
           #:Field #:field-key #:field-value
           #:Event #:event-level #:event-category #:event-message #:event-timestamp
           #:event-fields #:visible-fields
           #:render #:render-pretty #:render-json
           ;; the CL boundary: promised representations only
           #:valid-level-name? #:valid-layout-name? #:level-name-rank #:level-name-enabled?
           #:mk-field-string #:mk-field-raw #:render-event-line))

(cl:defpackage #:aion/log
  (:use #:cl)
  (:shadow #:trace #:debug #:warn #:error)   ; our leveled macros shadow the CL symbols
  (:local-nicknames (#:types #:aion/log/types)   ; the typed core: Level/Layout/Event
                    (#:lm   #:log)       ; log4cl's user macros (info/trace/... , config)
                    (#:l4   #:log4cl)    ; log4cl's appender/layout/logger config API
                    (#:jzon #:com.inuoe.jzon))
  (:documentation
   "Neutral leveled + structured logging over log4cl. SETUP configures per-env appenders
    (dev pretty / staging-prod JSON to stdout); TRACE/DEBUG/INFO/WARN/ERROR/FATAL log with a
    message + a plist of structured fields; WITH-CONTEXT adds ambient fields; EXCEPTION logs
    a condition with a backtrace; LEVEL! changes levels at runtime (also live from the REPL
    via log4cl).")
  (:export #:setup #:level! #:with-context #:*context* #:*layout*
           #:trace #:debug #:info #:warn #:error #:fatal #:exception))
