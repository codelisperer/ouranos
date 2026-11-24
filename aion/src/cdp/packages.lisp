;;;; packages.lisp --- aion/cdp: a Chrome DevTools Protocol client (#1028, dokimasia ADR-0001).
;;;;
;;;; A binding in the sense of ECOSYSTEM.md's placement rule: its specification is Chrome's
;;;; protocol documentation, and it decides nothing about what a test is. dokimasia decides
;;;; that; praxeon may use this to read pages that build their content with JavaScript.
;;;;
;;;; Headless only. LAUNCH-BROWSER always passes --headless=new and refuses arguments that
;;;; would change the headless mode, the debugging port or pipe, or the profile, and
;;;; ATTACH-BROWSER connects to a browser someone else started. No function here opens a
;;;; window.

(cl:defpackage #:aion/cdp
  (:use #:cl)
  (:local-nicknames (#:ws #:aion/websocket)
                    (#:jzon #:com.inuoe.jzon)
                    (#:log #:aion/log)
                    #-win32 (#:uv #:aion/uv)
                    #-win32 (#:proc #:aion/uv/process))
  (:documentation
   "A client for the Chrome DevTools Protocol, for Chrome and Edge.

FIND-BROWSER names the browser to run. LAUNCH-BROWSER starts it headless with a fresh
profile, ATTACH-BROWSER connects to one already running on this machine, CLOSE-BROWSER ends
what LAUNCH-BROWSER started, and WITH-BROWSER does both around a body. NEW-PAGE opens a tab.
The commands act on a page; SEND sends any other CDP method. Each page keeps its console
messages, exceptions, log entries and network events in order, and DRAIN-EVENTS returns and
clears them.

One reader thread per connection reads the browser's messages, hands each response to the
caller waiting for it, and appends events to their page's buffer. Failures are conditions:
BROWSER-NOT-FOUND, BROWSER-EXITED, CDP-ERROR, CDP-TIMEOUT, TARGET-CRASHED, and
ELEMENT-NOT-FOUND and EVALUATION-ERROR, both kinds of CDP-ERROR.")
  (:export
   ;; conditions
   #:cdp-condition #:browser-not-found #:browser-exited #:browser-exited-code
   #:browser-exited-signal #:browser-exited-output #:cdp-error #:cdp-error-method #:cdp-error-code
   #:cdp-error-message #:cdp-timeout #:cdp-timeout-what #:cdp-timeout-seconds
   #:target-crashed #:element-not-found #:element-not-found-selector #:evaluation-error
   #:connection-closed
   ;; finding, launching, attaching, closing
   #:find-browser #:browser-command-line #:fixed-browser-switches #:check-browser-arguments
   #:launch-browser #:attach-browser #:close-browser #:with-browser
   #:browser #:browser-p #:browser-pid #:browser-version #:browser-launched-p
   #:*default-timeout*
   ;; pages
   #:page #:page-p #:page-browser #:page-target-id #:new-page #:close-page
   ;; commands
   #:send #:navigate #:evaluate #:wait-for #:query #:text-of #:attribute-of #:click
   #:type-text #:set-viewport #:emulate-color-scheme #:screenshot
   ;; events
   #:event #:event-p #:event-method #:event-params #:drain-events #:page-events-dropped
   #:*max-buffered-events*
   ;; JSON helpers, for SEND's parameters and results
   #:json-object #:json-get))
