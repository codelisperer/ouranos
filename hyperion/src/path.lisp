;;;; path.lisp --- path templates and matching, in Coalton (the pure core of routing).
;;;;
;;;; A path template ("/contacts/:id/notes") parsed into a checked value, and matched
;;;; against a request path to yield the bound parameters. This is the half of routing
;;;; that is genuinely LOGIC -- classify, walk two lists in step, bind, decide -- so it
;;;; is the half that belongs in Coalton. The other half (handlers, the Clack env, the
;;;; response) is irreducibly effectful and lives in hyperion/router (CL). See
;;;; docs/adr/0012-routing-typed-paths-cl-dispatch.md.
;;;;
;;;; Template grammar, deliberately small:
;;;;   /contacts          a LITERAL segment -- must match exactly
;;;;   /:id               a PARAM -- matches one segment, binds it to "id"
;;;;   /*                 REST -- matches all remaining segments, binds them to "rest"
;;;;
;;;; Empty segments are dropped, so "/a/b", "/a/b/" and "a/b" are one template and a
;;;; trailing slash never decides a match. `*` is only meaningful last; a Rest segment
;;;; with anything after it makes every later segment unreachable, which PATTERN-VALID?
;;;; reports so the CL shell can signal at route-construction time rather than
;;;; mis-routing quietly at request time.
;;;;
;;;; The CL boundary (coalton-patterns.md §7): CL never inspects a Pattern. It receives
;;;; one as an opaque value from PARSE-PATTERN, hands it back to the matchers, and reads
;;;; only PROMISED representations -- Boolean and (List String). PATH-BINDINGS therefore
;;;; returns a FLAT name/value list rather than (List (Tuple String String)): a Tuple is
;;;; a define-type, whose representation Coalton does not promise across compilation
;;;; modes, and a CL caller destructuring one would work in development and break in
;;;; release.

(cl:in-package #:hyperion/path)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- Segment: what one template component can be -------------------------
  (define-type Segment
    "One component of a path template."
    (Literal String)   ; must equal the request's segment
    (Param String)     ; matches any one segment, binding it to this name
    Rest)              ; matches every remaining segment, joined, bound to "rest"

  ;; NOTE: list tails in this file are named `tail`, never `rest`. Coalton is
  ;; case-insensitive, so a variable `rest` IS the `Rest` constructor above --
  ;; docs/coalton-patterns.md 8b. It compiled here on SBCL 2.6.5 and failed for a
  ;; consuming app on a different build, which is the worst way to find out.

  (define-type Pattern
    "A parsed path template: its segments, in order."
    (Pattern (List Segment)))

  (declare pattern-segments (Pattern -> (List Segment)))
  (define (pattern-segments p)
    (match p ((Pattern ss) ss)))

  ;;; --- Parsing -------------------------------------------------------------
  ;; Splitting on #\/ yields an empty string for a leading, trailing, or doubled
  ;; slash; dropping them is what makes "/a/b" and "/a/b/" the same template.
  (declare %split (String -> (List String)))
  (define (%split s)
    (filter (fn (x) (not (== x ""))) (str:split #\/ s)))

  (declare %classify (String -> Segment))
  (define (%classify s)
    (match (str:strip-prefix ":" s)
      ((Some name) (Param name))
      ((None) (if (== s "*") Rest (Literal s)))))

  (declare parse-pattern (String -> Pattern))
  (define (parse-pattern template)
    "Parse a path TEMPLATE into a Pattern. Total -- every string is some pattern;
use PATTERN-VALID? to reject the one shape that is structurally useless."
    (Pattern (map %classify (%split template))))

  ;;; --- Introspection (the route set is data) -------------------------------
  (declare %param-names ((List Segment) -> (List String)))
  (define (%param-names ss)
    (match ss
      ((Nil) Nil)
      ((Cons s tail)
       (match s
         ((Param n) (Cons n (%param-names tail)))
         ((Rest) (Cons "rest" (%param-names tail)))
         ((Literal _) (%param-names tail))))))

  (declare pattern-params (Pattern -> (List String)))
  (define (pattern-params p)
    "The parameter names this pattern binds, in template order. A Rest segment
contributes \"rest\". Lets the CL shell report a route's parameters, and detect a
duplicate name before it silently shadows."
    (%param-names (pattern-segments p)))

  ;; A Rest anywhere but last makes every following segment unreachable. That is a
  ;; typo, not an intention, so it is reported rather than accommodated.
  (declare %rest-only-last? ((List Segment) -> Boolean))
  (define (%rest-only-last? ss)
    (match ss
      ((Nil) True)
      ((Cons s tail)
       (match s
         ((Rest) (match tail ((Nil) True) ((Cons _ _) False)))
         ((Param _) (%rest-only-last? tail))
         ((Literal _) (%rest-only-last? tail))))))

  (declare pattern-valid? (Pattern -> Boolean))
  (define (pattern-valid? p)
    "False when a Rest (`*`) segment is followed by anything -- those segments could
never match. Every other pattern is valid."
    (%rest-only-last? (pattern-segments p)))

  ;;; --- Matching ------------------------------------------------------------
  (declare %join ((List String) -> String))
  (define (%join xs)
    (match xs
      ((Nil) "")
      ((Cons x (Nil)) x)
      ((Cons x tail) (<> x (<> "/" (%join tail))))))

  ;; Walk template and path in step, accumulating bindings in reverse. Returns None
  ;; the moment they disagree -- a literal that differs, or either side running out
  ;; while the other has segments left. Exhaustive on Segment, so adding a segment
  ;; kind is a compile error here rather than a silent fallthrough.
  (declare %walk ((List Segment) * (List String) * (List (Tuple String String))
                  -> (Optional (List (Tuple String String)))))
  (define (%walk pat path acc)
    (match pat
      ((Nil)
       (match path
         ((Nil) (Some (reverse acc)))
         ((Cons _ _) None)))              ; path has more segments than the template
      ((Cons s tail)
       (match s
         ;; Rest matches the remainder INCLUDING nothing, so "/files/*" matches
         ;; "/files" with the "rest" parameter bound to "".
         ((Rest) (Some (reverse (Cons (Tuple "rest" (%join path)) acc))))
         ((Literal lit)
          (match path
            ((Nil) None)
            ((Cons p prest)
             (if (== p lit) (%walk tail prest acc) None))))
         ((Param nm)
          (match path
            ((Nil) None)
            ((Cons p prest) (%walk tail prest (Cons (Tuple nm p) acc)))))))))

  (declare %flatten ((List (Tuple String String)) -> (List String)))
  (define (%flatten bs)
    (match bs
      ((Nil) Nil)
      ((Cons (Tuple k v) tail) (Cons k (Cons v (%flatten tail))))))

  ;;; --- The CL-facing surface (promised representations only) ---------------
  (declare path-matches? (Pattern * String -> Boolean))
  (define (path-matches? p path)
    "Does PATH match pattern P? The method is not consulted -- which is exactly what
lets the CL shell tell 405 (this path exists, that method does not) from 404."
    (match (%walk (pattern-segments p) (%split path) Nil)
      ((Some _) True)
      ((None) False)))

  (declare path-bindings (Pattern * String -> (List String)))
  (define (path-bindings p path)
    "PATH's parameter bindings against P as a FLAT name/value list
 (\"id\" \"42\" ...) -- a promised representation the CL shell can walk directly.
Empty both when nothing matched and when a match bound nothing; callers that need
to tell those apart ask PATH-MATCHES? first."
    (match (%walk (pattern-segments p) (%split path) Nil)
      ((Some bs) (%flatten bs))
      ((None) Nil)))

  (declare normalize-path (String -> String))
  (define (normalize-path path)
    "PATH with empty segments dropped and a single leading slash -- the canonical form
matching compares. Used by the CL shell when it strips a mount prefix, so a mounted
sub-router sees the same shape a top-level one would."
    (<> "/" (%join (%split path)))))
