;;;; dev-port-tests.lisp --- derived development ports (pre-publication issue 238).
;;;;
;;;; The port collision is the symptom; the LITERAL IN THE TEMPLATE is the defect, and
;;;; every application generated from that file inherits it.

(in-package #:cons/tests)

;;;; --- pre-publication issue 238: a template must not ship a literal dev port ----------------------

(def-suite dev-port :description "Derived development ports (pre-publication issue 238)." :in all)
(in-suite dev-port)

(test the-same-name-always-derives-the-same-port
  ;; A project regenerated next year must get the port its README documents today, which
  ;; is why this is an explicit FNV-1a rather than SXHASH (whose value for a string is not
  ;; promised to be stable across SBCL versions).
  (is (= (cons/init:dev-port "acme") (cons/init:dev-port "acme")))
  (is (= (cons/init:dev-port "acme") (cons/init:dev-port "ACME"))
      "case must not change the derivation -- a project is one project"))

(test derived-ports-sit-below-every-os-ephemeral-range
  ;; Windows hands out 49152+, Linux 32768+. Staying below both means a generated port can
  ;; never collide with one the OS assigned to something else by accident.
  (dolist (name '("a" "acme" "wordcrafter" "soloflow" "a-rather-long-project-name" "x9"))
    (let ((p (cons/init:dev-port name)))
      (is (<= cons/init:+dev-port-base+ p)
          "~A derived ~D, below the block" name p)
      (is (< p (+ cons/init:+dev-port-base+ cons/init:+dev-port-span+))
          "~A derived ~D, above the block" name p)
      (is (< p 32768) "~A derived ~D, inside Linux's ephemeral range" name p))))

(test different-names-do-not-all-collapse-to-one-port
  ;; The derivation is not a uniqueness guarantee -- two names can collide, which is what
  ;; HYPERION/SERVER's preflight is for -- but a hash that returned a constant would pass
  ;; every other test here while reintroducing the exact defect.
  (let ((ports (mapcar #'cons/init:dev-port
                       '("alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta" "theta"))))
    (is (> (length (remove-duplicates ports)) 6)
        "8 names produced ~D distinct ports: ~S" (length (remove-duplicates ports)) ports)))

(test no-template-ships-a-literal-8080
  ;; The root cause, asserted against the shipped templates rather than described. If a
  ;; future template hardcodes a port, this fails when it is added, not when two apps
  ;; collide in somebody's afternoon.
  (let ((offenders '()))
    (dolist (dir (directory (merge-pathnames "cons/templates/*/"
                                             (asdf:system-source-directory "cons"))))
      (dolist (f (directory (merge-pathnames "**/*.*" dir)))
        (when (and (pathname-name f)
                   (member (pathname-type f) '("lisp" "asd" "md" "toml") :test #'equal))
          (let ((text (uiop:read-file-string f)))
            (when (search "8080" text)
              (push (enough-namestring f) offenders))))))
    (is (null offenders) "a template hardcodes port 8080: ~S" offenders)))
