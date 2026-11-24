;;;; state.lisp --- the typed core of the window desktop: a window's state, the events that
;;;; change it, and the function that applies one event to one state (#1218).
;;;;
;;;; Everything here is pure. The CL shell (desktop.lisp) reads the request, builds an event
;;;; with one of the constructors below, calls APPLY-EVENT, and stores the state it returns.
;;;; The shell never looks inside a state or an event: it reads them through the accessors
;;;; at the end of this file, which return integers, strings and booleans
;;;; (docs/coalton-patterns.md, section 7).

(cl:defpackage #:hyperion/desktop-ui/state
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "A window's position, size, stacking order and visibility; the events that change them;
    and APPLY-EVENT, the pure function from an event and a state to the next state.")
  (:export #:Win-State #:Win-Event
           #:make-state #:apply-event
           #:move-event #:resize-event #:raise-event #:close-event #:open-event
           #:state-x #:state-y #:state-width #:state-height #:state-z #:state-shown?
           #:event-name #:event-arguments
           #:minimum-width #:minimum-height))

(cl:in-package #:hyperion/desktop-ui/state)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; Whether a window is on the page. A type of its own, not a Boolean, so a third case
  ;; (minimised, say) is a new constructor and every MATCH on it is checked again.
  (define-type Visibility
    Shown
    Hidden)

  ;; x, y, width, height, z, visibility. x and y are the top-left corner in CSS pixels from
  ;; the desktop's top-left corner. A window with a higher z is drawn over one with a lower z.
  (define-type Win-State
    (Win-State Integer Integer Integer Integer Integer Visibility))

  ;; What can happen to a window. The page sends these; a REPL or a test can send them too.
  (define-type Win-Event
    (Moved Integer Integer)      ; the new x and y
    (Resized Integer Integer)    ; the new width and height
    (Raised Integer)             ; the z to move to; the shell supplies one above every window
    Closed
    Opened)

  (declare minimum-width Integer)
  (define minimum-width 120)

  (declare minimum-height Integer)
  (define minimum-height 60)

  (declare apply-event (Win-Event * Win-State -> Win-State))
  (define (apply-event event state)
    "The state after EVENT. A move never leaves the window above or left of the desktop, a
resize never makes it smaller than the minimum, and a raise never lowers it."
    (match state
      ((Win-State x y width height z visibility)
       (match event
         ((Moved new-x new-y)
          (Win-State (max 0 new-x) (max 0 new-y) width height z visibility))
         ((Resized new-width new-height)
          (Win-State x y (max minimum-width new-width) (max minimum-height new-height)
                     z visibility))
         ((Raised new-z)
          (Win-State x y width height (max z new-z) visibility))
         ((Closed)
          (Win-State x y width height z Hidden))
         ((Opened)
          (Win-State x y width height z Shown))))))

  ;; --- constructors the CL shell calls ---

  (declare make-state (Integer * Integer * Integer * Integer * Integer -> Win-State))
  (define (make-state x y width height z)
    "A shown window at X, Y with the given size and stacking order, held to the same limits
APPLY-EVENT keeps."
    (apply-event (Resized width height)
                 (apply-event (Moved x y) (Win-State 0 0 0 0 z Shown))))

  (declare move-event (Integer * Integer -> Win-Event))
  (define (move-event x y) (Moved x y))

  (declare resize-event (Integer * Integer -> Win-Event))
  (define (resize-event width height) (Resized width height))

  (declare raise-event (Integer -> Win-Event))
  (define (raise-event z) (Raised z))

  (declare close-event Win-Event)
  (define close-event Closed)

  (declare open-event Win-Event)
  (define open-event Opened)

  ;; --- accessors the CL shell calls ---

  (declare state-x (Win-State -> Integer))
  (define (state-x state) (match state ((Win-State x _ _ _ _ _) x)))

  (declare state-y (Win-State -> Integer))
  (define (state-y state) (match state ((Win-State _ y _ _ _ _) y)))

  (declare state-width (Win-State -> Integer))
  (define (state-width state) (match state ((Win-State _ _ width _ _ _) width)))

  (declare state-height (Win-State -> Integer))
  (define (state-height state) (match state ((Win-State _ _ _ height _ _) height)))

  (declare state-z (Win-State -> Integer))
  (define (state-z state) (match state ((Win-State _ _ _ _ z _) z)))

  (declare state-shown? (Win-State -> Boolean))
  (define (state-shown? state)
    (match state
      ((Win-State _ _ _ _ _ (Shown)) True)
      ((Win-State _ _ _ _ _ (Hidden)) False)))

  (declare event-name (Win-Event -> String))
  (define (event-name event)
    "The word the page sends for EVENT, and the inspector shows."
    (match event
      ((Moved _ _) "move")
      ((Resized _ _) "resize")
      ((Raised _) "raise")
      ((Closed) "close")
      ((Opened) "open")))

  (declare event-arguments (Win-Event -> (List Integer)))
  (define (event-arguments event)
    "The numbers EVENT carries, in the order its constructor takes them."
    (match event
      ((Moved x y) (make-list x y))
      ((Resized width height) (make-list width height))
      ((Raised z) (make-list z))
      ((Closed) Nil)
      ((Opened) Nil))))
